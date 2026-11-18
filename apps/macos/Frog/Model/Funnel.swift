import Foundation

/// Funnel events from the Mac (docs/design/funnel/events.md), sent only when the person turned
/// on **Share usage with Frog** (Settings › General; off by default). They go to the Frog Cloud
/// gateway's `POST /v1/events`, never straight to PostHog. The gateway forwards only allow-listed
/// names and values, and drops everything while PostHog isn't configured there.
///
/// Signed in, the gateway takes who it is from the key. Signed out, the Mac sends a random
/// install id, made when the setting is turned on and deleted when it's turned off. The first
/// signed-in event carries that id once, so the gateway can join this Mac's local-model steps to
/// the account. Nothing else: no prompt, no model name (only `apple` or `local`), no file,
/// folder, repo, device name or hardware id.
@MainActor
enum Funnel {
    /// The setting (`@AppStorage` in Settings › General).
    static let optInKey = "shareUsage"
    static let installKey = "funnel.installID"
    /// The install id has gone along with a signed-in event once, so the gateway joined it.
    static let joinedKey = "funnel.joined"

    static var defaults: UserDefaults = .standard
    /// Sends one request; tests swap it. Best effort: a failure is dropped.
    static var send: (URLRequest) -> Void = { r in
        // A test host shares the app's defaults: never send from one.
        guard !SingleInstance.isTesting else { return }
        Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: r) }
    }
    /// The signed-in key, if any (tests swap it).
    static var key: () -> String? = { CloudAccount.shared.key }

    static var optedIn: Bool { defaults.bool(forKey: optInKey) }

    /// The setting was turned off: forget the install id, so turning it on again is a new install.
    static func forget() {
        defaults.removeObject(forKey: installKey)
        defaults.removeObject(forKey: joinedKey)
    }

    private static func installID() -> String {
        if let id = defaults.string(forKey: installKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installKey)
        return id
    }

    /// The request for one event, or nil when the person hasn't opted in.
    static func request(_ event: String, _ props: [String: Any] = [:]) -> URLRequest? {
        guard optedIn else { return nil }
        let key = key()
        var body: [String: Any] = ["event": event, "props": props]
        if key == nil || !defaults.bool(forKey: joinedKey) { body["anon"] = installID() }
        if key != nil { defaults.set(true, forKey: joinedKey) }
        var r = URLRequest(url: CloudGateway.origin.appending(path: "v1/events"))
        r.httpMethod = "POST"
        r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    static func track(_ event: String, _ props: [String: Any] = [:]) {
        if let r = request(event, props) { send(r) }
    }

    // MARK: - The moments

    /// The kind of model a spec names, for `local_answer`: nil for anything that isn't on this Mac.
    static func localKind(of spec: String?) -> String? {
        guard let spec else { return nil }
        switch ProviderID.of(spec: spec) {
        case "apple": return "apple"
        case ProviderID.local, "ollama", "lmstudio": return "local"
        default: return nil
        }
    }

    /// A live turn finished: on a model on this Mac, completed, it's a local answer.
    static func turnEnded(model: String?, cloud: Bool, end: EndReason?) {
        guard !cloud, case .complete? = end, let kind = localKind(of: model) else { return }
        track("local_answer", ["model": kind])
    }

    /// The person answered a permission prompt: allowing an edit is the funnel's "their project" step.
    static func decided(tool: String, _ d: Decision) {
        guard d != .deny, ["Edit", "MultiEdit", "Write"].contains(tool) else { return }
        track("edit_accepted")
    }
}

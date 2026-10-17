import Foundation

/// What widgets, controls and the share sheet know about the Mac: the conversations that need you
/// or are running, as of the app's last look. Written by the app into the shared group.
struct Snapshot: Codable, Equatable {
    struct Row: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        /// "waiting", "running", "unread" or "".
        var live: String
        var activity: String?
        var question: String?
        var permission: String?
        var local: Bool
        /// Open in a window on the Mac, so it can take messages.
        var open: Bool = false
        /// frog's own question (the `Ask` tool), while it waits on one.
        var ask: Ask? = nil
        /// The last thing frog said, for the wrist.
        var last: String? = nil
        /// The last turn's headline stats ("disk: 42 GB") and next-step buttons (Present).
        var stats: [String]? = nil
        var actions: [Action]? = nil

        var waiting: Bool { live == "waiting" }
    }

    /// An `Ask`: pick an option, or (if `other`) say something else.
    struct Ask: Codable, Hashable {
        var id: String
        var question: String
        var options: [String]
        var other: Bool
    }

    /// A Present actions button: `send` (or the label) becomes the next message.
    struct Action: Codable, Hashable {
        var label: String
        var send: String
    }

    var rows: [Row]
    var host: String?
    var at: Date

    static let group = "group.eco.frog.remote"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    var waiting: [Row] { rows.filter { $0.live == "waiting" } }
    var running: [Row] { rows.filter { $0.live == "running" } }

    static func load() -> Snapshot? {
        defaults.data(forKey: "snapshot").flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    func save() {
        Self.defaults.set(try? JSONEncoder().encode(self), forKey: "snapshot")
    }

    /// Where the Mac is and the code it wants (from the Keychain), for extensions that talk to it.
    static var connection: (host: String, code: String)? {
        guard let code = PairingCode.read(), !code.isEmpty, let host = defaults.string(forKey: "host") else { return nil }
        return (host, code)
    }

    static func remember(host: String) {
        defaults.set(host, forKey: "host")
    }
}

extension Snapshot.Row {
    /// A row of the Mac's session list (`sessions` on the bridge), as the watch reads it directly.
    init?(bridge r: [String: Any]) {
        guard let id = r["id"] as? String, (r["archived"] as? Bool) != true else { return nil }
        let q = r["question"] as? [String: Any]
        let name = q?["name"] as? String ?? ""
        let arg = q?["arg"] as? String ?? ""
        self.init(id: id, title: r["title"] as? String ?? "frog", live: r["live"] as? String ?? "",
                  activity: r["activity"] as? String,
                  question: q.map { _ in PermissionRequest.question(name: name, arg: arg) },
                  permission: q?["id"] as? String, local: true, open: r["open"] as? Bool ?? false,
                  ask: Snapshot.Ask(r["ask"]), last: r["last"] as? String,
                  stats: r["stats"] as? [String],
                  actions: (r["actions"] as? [[String: String]])?.compactMap { a in
                      a["label"].map { Snapshot.Action(label: $0, send: a["send"] ?? "") }
                  })
    }
}

extension Snapshot.Ask {
    init?(_ any: Any?) {
        guard let a = any as? [String: Any], let id = a["id"] as? String else { return nil }
        self.init(id: id, question: a["question"] as? String ?? "", options: a["options"] as? [String] ?? [],
                  other: a["other"] as? Bool ?? false)
    }
}

import Foundation
import Observation

/// The connection to frog on your Mac (`RemoteBridge` there): one WebSocket, the session list,
/// and the conversation you're looking at. Reconnects on its own, and picks a conversation up
/// from the last event it saw, so nothing arrives twice and nothing is missed.
@MainActor
@Observable
final class Remote: SessionLink {
    /// The one connection, shared with notification actions and intents.
    static let shared = Remote()

    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSession] = []
    private(set) var open: SessionModel?
    /// A conversation someone asked to see (a tapped notification, Handoff, a widget).
    var requested: String?

    /// A Bonjour name ("Cam's MacBook Pro") or host:port; 127.0.0.1:8913 is the Mac this
    /// Simulator runs on.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "remoteHost") }
    }
    var code: String {
        didSet {
            PairingCode.write(code)
            Snapshot.remember(host: host)
        }
    }

    @ObservationIgnored private var socket: BridgeSocket?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Said before the Mac let us in; sent as soon as it does.
    @ObservationIgnored private var outbox: [[String: Any]] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var listWaiters: [CheckedContinuation<[RemoteSession], Never>] = []
    /// Requests waiting on the Mac's answer, by ref: a session id, or why not.
    @ObservationIgnored private var asks: [String: CheckedContinuation<Result<String, AskError>, Never>] = [:]

    struct AskError: Error { let message: String }

    init() {
        let env = ProcessInfo.processInfo.environment
        host = env["FROG_REMOTE_HOST"] ?? UserDefaults.standard.string(forKey: "remoteHost") ?? ""
        // Codes kept in defaults by earlier builds move to the Keychain.
        if let old = UserDefaults.standard.string(forKey: "remoteCode") {
            PairingCode.write(old)
            UserDefaults.standard.removeObject(forKey: "remoteCode")
            Snapshot.defaults.removeObject(forKey: "code")
        }
        code = env["FROG_REMOTE_CODE"] ?? PairingCode.read() ?? ""
    }

    var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    // MARK: Connection

    func connect() {
        retry?.cancel()
        socket?.cancel()
        guard !code.isEmpty, !host.isEmpty else {
            state = .failed("Enter the code from Frog's settings on your Mac.")
            return
        }
        generation += 1
        let gen = generation
        state = .connecting
        let s = BridgeSocket(host: host, code: code)
        s.onReady = { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.send(["type": "hello", "token": self.code])
            }
        }
        s.onMessage = { [weak self] data in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.handle(data)
            }
        }
        s.onClose = { [weak self] error, early in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                // A TLS failure before we're in means the key (the code) didn't match.
                if early, case .tls? = error {
                    self.retry?.cancel()
                    self.state = .failed("That code didn't match. Check Frog's settings on your Mac.")
                    return
                }
                self.lost(error?.localizedDescription ?? "closed", gen)
            }
        }
        socket = s
        s.start()
    }

    /// Stop talking to the Mac; `forget` also drops the code, back to the connect screen.
    func disconnect(forget: Bool = false) {
        if forget { code = "" }
        retry?.cancel()
        generation += 1
        socket?.cancel()
        socket = nil
        state = .idle
    }

    /// Pair from a `frog://pair` link (the QR code in the Mac's settings) and connect.
    func pair(_ url: URL) -> Bool {
        guard let p = Pairing.parse(url) else { return false }
        host = p.host ?? p.name
        code = p.code
        connect()
        return true
    }

    /// Dropped: try again shortly, unless the Mac turned us away.
    private func lost(_ why: String, _ gen: Int) {
        if case .failed = state { return }
        let wasConnected = isConnected
        state = .failed(wasConnected ? "Lost the connection. Reconnecting…" : "Can't reach frog on \(host). Is “Let frog on iPhone connect” on?")
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.connect()
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["type"] as? String {
        case "welcome":
            state = .connected(host: msg["host"] as? String ?? "Mac")
            Snapshot.remember(host: host)
            registerForPushes()
            for m in outbox { send(m) }
            outbox = []
            waiters.forEach { $0.resume(returning: true) }
            waiters = []
            refresh()
            // Back after a drop: carry on where the transcript left off.
            if let open { send(["type": "attach", "session": open.id, "after": open.lastSeq]) }
        case "sessions":
            let rows = msg["sessions"] as? [[String: Any]] ?? []
            sessions = rows.compactMap(RemoteSession.init)
            listWaiters.forEach { $0.resume(returning: sessions) }
            listWaiters = []
            WatchLink.shared.share(sessions)
            Glance.share(sessions, host: { if case .connected(let h) = state { h } else { nil } }())
            open?.isOpenOnMac = sessions.first { $0.id == open?.id }?.open ?? false
        case "event":
            guard let env = msg["env"],
                  let raw = try? JSONSerialization.data(withJSONObject: env),
                  let envelope = try? JSONDecoder.frog.decode(Envelope.self, from: raw),
                  envelope.session == open?.id else { return }
            open?.apply(envelope, raw: raw)
        case "synced":
            if (msg["session"] as? String) == open?.id { open?.synced() }
        case "opened":
            let id = msg["session"] as? String ?? ""
            if let ref = msg["ref"] as? String, let ask = asks.removeValue(forKey: ref) { ask.resume(returning: .success(id)) }
            if open?.id == id { open?.isOpenOnMac = true }
        case "error" where (msg["ref"] as? String).map { asks[$0] != nil } ?? false:
            let ref = msg["ref"] as! String
            asks.removeValue(forKey: ref)?.resume(returning: .failure(AskError(message: msg["message"] as? String ?? "Something went wrong")))
        case "error":
            let text = msg["message"] as? String ?? "Something went wrong"
            if msg["session"] != nil { open?.note(text) }
            else if !isConnected {
                retry?.cancel()
                generation += 1
                state = .failed(text == "wrong code" ? "That code didn't match. Check Frog's settings on your Mac." : text)
            }
        default:
            break
        }
    }

    // MARK: Sessions

    func refresh() {
        send(["type": "list"])
    }

    func attach(_ session: RemoteSession) -> SessionModel {
        if let open, open.id == session.id { return open }
        if let open { send(["type": "detach", "session": open.id]) }
        let model = SessionModel(session: session, link: self)
        open = model
        send(["type": "attach", "session": session.id, "after": model.lastSeq])
        return model
    }

    func detach(_ model: SessionModel) {
        guard open === model else { return }
        send(["type": "detach", "session": model.id])
        model.close()
        open = nil
    }

    func send(op: [String: Any], in session: String) {
        send(["type": "op", "session": session, "op": op])
    }

    /// Do something on the Mac from wherever we are (a notification's button, an intent):
    /// connect if we must, wait to be let in, then send. False if the Mac didn't answer in time.
    @discardableResult
    func perform(op: [String: Any], in session: String) async -> Bool {
        let message: [String: Any] = ["type": "op", "session": session, "op": op]
        if isConnected {
            send(message)
            return true
        }
        outbox.append(message)
        if state != .connecting { connect() }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            Task {
                try? await Task.sleep(for: .seconds(8))
                // Still not let in: give up on everyone waiting.
                let late = self.waiters
                self.waiters = []
                late.forEach { $0.resume(returning: false) }
            }
        }
    }

    /// Answer a question from a list, the watch or a widget, without opening its thread.
    func answer(_ q: RemoteSession.Question, in session: String, allow: Bool) {
        Task {
            await perform(op: ["op": "permission", "id": q.id, "decision": allow ? "allow" : "deny"], in: session)
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
        }
    }

    /// Open a conversation in a window on the Mac, so it can take messages.
    func openOnMac(_ id: String) async -> Result<String, AskError> {
        await ask(["type": "open", "session": id])
    }

    /// Start a new conversation on the Mac (a chat, or in the folder of `like`) with `text`.
    func startNew(_ text: String, like: String?) async -> Result<String, AskError> {
        var m: [String: Any] = ["type": "new", "text": text]
        if let like { m["like"] = like }
        return await ask(m)
    }

    private func ask(_ message: [String: Any]) async -> Result<String, AskError> {
        let ref = UUID().uuidString
        var m = message
        m["ref"] = ref
        if isConnected { send(m) } else { outbox.append(m); if state != .connecting { connect() } }
        return await withCheckedContinuation { cont in
            asks[ref] = cont
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.asks.removeValue(forKey: ref)?.resume(returning: .failure(AskError(message: "Your Mac didn't answer.")))
            }
        }
    }

    /// The Mac's conversations as of now, connecting if we must (for Siri and Shortcuts). What we
    /// already have if the Mac doesn't answer in a few seconds.
    func listNow() async -> [RemoteSession] {
        if !isConnected, state != .connecting { connect() }
        return await withCheckedContinuation { cont in
            listWaiters.append(cont)
            if isConnected { refresh() } else { outbox.append(["type": "list"]) }
            Task {
                try? await Task.sleep(for: .seconds(5))
                let late = self.listWaiters
                self.listWaiters = []
                late.forEach { $0.resume(returning: self.sessions) }
            }
        }
    }

    /// Tell the Mac how to reach this phone when the app is asleep.
    private func registerForPushes() {
        #if targetEnvironment(simulator)
        if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            send(["type": "register", "transport": "simctl", "address": udid, "bundle": Bundle.main.bundleIdentifier ?? ""])
        }
        #else
        if let token = Notifications.shared.deviceToken {
            send(["type": "register", "transport": "apns", "address": token, "bundle": Bundle.main.bundleIdentifier ?? "",
                  "env": Notifications.apnsEnvironment])
        }
        #endif
    }

    /// Where a Live Activity for `session` takes its updates.
    func registerActivity(session: String, token: String?) {
        send(["type": "activity", "session": session, "token": token ?? NSNull()])
    }

    private func send(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        socket.send(String(decoding: data, as: UTF8.self))
    }
}

/// A row in the session list.
struct RemoteSession: Identifiable, Hashable {
    enum Live: String { case running, waiting, unread }

    let id: String
    let title: String
    let folder: String?
    let model: String
    let modified: Date
    let chat: Bool
    /// Open in a window on the Mac, so it can take messages.
    let open: Bool
    let pinned: Bool
    let live: Live?
    /// The step in hand, while it runs.
    let activity: String?
    /// What frog is asking, while it waits.
    let question: Question?

    struct Question: Hashable {
        let id: String
        let name: String
        let arg: String

        /// "Run cargo test?", "Edit main.rs?"
        var text: String {
            switch name {
            case "Bash": "Run \(arg.split(separator: "\n").first.map(String.init) ?? arg)?"
            case "Edit", "Write": "\(name) \((arg as NSString).lastPathComponent)?"
            default: "Use \(name)?"
            }
        }
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        self.id = id
        title = row["title"] as? String ?? "Untitled"
        folder = row["folder"] as? String
        model = row["model"] as? String ?? ""
        modified = Date(timeIntervalSince1970: ((row["modified"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        chat = row["chat"] as? Bool ?? false
        open = row["open"] as? Bool ?? false
        pinned = row["pinned"] as? Bool ?? false
        live = (row["live"] as? String).flatMap(Live.init)
        activity = row["activity"] as? String
        question = (row["question"] as? [String: Any]).flatMap { q in
            (q["id"] as? String).map { Question(id: $0, name: q["name"] as? String ?? "", arg: q["arg"] as? String ?? "") }
        }
    }

    /// Runs on your own hardware (blue), or on someone's data center (green), like the Mac.
    var isLocal: Bool { Models.isLocal(model) }
}

enum Models {
    static let localPrefixes = ["tang/", "apple/", "ollama/", "lmstudio/", "llamacpp/", "mlx/", "vllm/", "node/"]
    static func isLocal(_ spec: String) -> Bool { localPrefixes.contains { spec.hasPrefix($0) } }

    /// "ollama/qwen3-coder:30b" → "qwen3-coder:30b"
    static func short(_ spec: String) -> String {
        let name = spec.split(separator: "/", maxSplits: 1).last.map(String.init) ?? spec
        return name.split(separator: "/").last.map(String.init) ?? name
    }
}

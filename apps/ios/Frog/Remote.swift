import Foundation
import Observation

/// The connection to frog on your Mac (`RemoteBridge` there): one WebSocket, the session list,
/// and the conversation you're looking at. Reconnects on its own, and picks a conversation up
/// from the last event it saw, so nothing arrives twice and nothing is missed.
@MainActor
@Observable
final class Remote {
    /// The one connection, shared with notification actions and intents.
    static let shared = Remote()

    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Has reached this Mac with this code: the app opens on the list, even offline.
    private(set) var paired = UserDefaults.standard.bool(forKey: "remotePaired") {
        didSet { UserDefaults.standard.set(paired, forKey: "remotePaired") }
    }
    private(set) var sessions: [RemoteSession] = []
    /// The Mac's archive, for its own page.
    private(set) var archived: [RemoteSession] = []

    /// A conversation by id, archived or not.
    func session(_ id: String) -> RemoteSession? {
        sessions.first { $0.id == id } ?? archived.first { $0.id == id }
    }
    /// The conversation on screen, and how it reaches the Mac.
    private(set) var open: Conversation?
    @ObservationIgnored private(set) var openLink: RemoteLink?
    /// The Mac's models and the providers behind them, so a model is named and placed here the
    /// way it is there (see `ModelContext`).
    private(set) var models: [ModelEntry] = []
    private(set) var providers: [ProviderInfo] = []
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
    /// `perform` calls waiting to be let in, each under its own token.
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var listWaiters: [CheckedContinuation<[RemoteSession], Never>] = []
    /// Requests waiting on the Mac's answer, by ref: a session id, or why not.
    @ObservationIgnored private var asks: [String: CheckedContinuation<Result<Reply, AskError>, Never>] = [:]

    struct AskError: Error { let message: String }
    /// The Mac's answer, as it came (JSON, only ever read on the main actor).
    struct Reply: @unchecked Sendable { let msg: [String: Any] }

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
        if forget {
            code = ""
            paired = false
            sessions = []
        }
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
        // The answer to something we asked (open, new, fork, a diagram…).
        if let ref = msg["ref"] as? String, !ref.isEmpty, let ask = asks.removeValue(forKey: ref) {
            ask.resume(returning: msg["type"] as? String == "error"
                ? .failure(AskError(message: msg["message"] as? String ?? "Something went wrong")) : .success(Reply(msg: msg)))
        }
        switch msg["type"] as? String {
        case "welcome":
            state = .connected(host: msg["host"] as? String ?? "Mac")
            paired = true
            Snapshot.remember(host: host)
            registerForPushes()
            for m in outbox { send(m) }
            outbox = []
            waiters.values.forEach { $0.resume(returning: true) }
            waiters = [:]
            refresh()
            // Back after a drop: carry on where the transcript left off.
            if let openLink { attach(openLink.session, after: openLink.lastSeq) }
        case "context":
            let dec = JSONDecoder()
            if let m = msg["models"].flatMap({ try? JSONSerialization.data(withJSONObject: $0) }) {
                models = (try? dec.decode([ModelEntry].self, from: m)) ?? models
            }
            if let p = msg["providers"].flatMap({ try? JSONSerialization.data(withJSONObject: $0) }) {
                providers = (try? dec.decode([ProviderInfo].self, from: p)) ?? providers
            }
        case "stats":
            // The Mac's spend and energy record; the phone records nothing of its own.
            if let st = msg["stats"].flatMap({ try? JSONSerialization.data(withJSONObject: $0) }) {
                ModelStats.shared.adopt(st, cap: msg["cap"] as? Double ?? 0)
            }
            if UserDefaults.standard.object(forKey: ModelStats.energyKey) == nil, let show = msg["show_energy"] as? Bool {
                UserDefaults.standard.set(show, forKey: ModelStats.energyKey)
            }
        case "sessions":
            let rows = (msg["sessions"] as? [[String: Any]] ?? []).compactMap(RemoteSession.init)
            sessions = rows.filter { !$0.archived }
            archived = rows.filter(\.archived)
            listWaiters.forEach { $0.resume(returning: sessions) }
            listWaiters = []
            WatchLink.shared.share(sessions)
            Glance.share(sessions, host: { if case .connected(let h) = state { h } else { nil } }())
            if let openLink { openLink.isOpenOnMac = sessions.first { $0.id == openLink.session }?.open ?? false }
        case "event":
            guard let env = msg["env"],
                  let raw = try? JSONSerialization.data(withJSONObject: env),
                  let envelope = try? JSONDecoder.frog.decode(Envelope.self, from: raw),
                  envelope.session == openLink?.session else { return }
            openLink?.receive(envelope, raw: raw)
        case "synced":
            if (msg["session"] as? String) == openLink?.session {
                openLink?.synced(upto: (msg["upto"] as? NSNumber)?.uint64Value ?? 0)
            }
        case "opened":
            let id = msg["session"] as? String ?? ""
            if openLink?.session == id { openLink?.isOpenOnMac = true }
        case "error" where msg["ref"] != nil:
            break
        case "error":
            let text = msg["message"] as? String ?? "Something went wrong"
            if (msg["session"] as? String) == openLink?.session { openLink?.refused(text) }
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

    /// The conversation for `session`, reaching the Mac through the bridge.
    func conversation(_ session: RemoteSession) -> Conversation {
        // By the link: the conversation only learns its id once the history is in, and the view
        // asks again before then.
        if let open, openLink?.session == session.id { return open }
        open?.stop()
        let link = RemoteLink(session: session.id, remote: self, open: session.open)
        let folder = URL(fileURLWithPath: session.cwd ?? FrogPaths.chatSuffix)
        let c = Conversation(folder: folder, link: link, replay: true, session: session.id)
        openLink = link
        open = c
        return c
    }

    /// Done looking at `c`.
    func close(_ c: Conversation) {
        guard open === c else { return }
        c.stop()
        open = nil
        openLink = nil
    }

    /// Ask the Mac for a conversation's history after `seq`, then what happens next.
    func attach(_ session: String, after seq: UInt64) {
        send(["type": "attach", "session": session, "after": seq])
    }

    func detach(_ session: String) {
        send(["type": "detach", "session": session])
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
            let token = UUID()
            waiters[token] = cont
            Task {
                try? await Task.sleep(for: .seconds(8))
                // Still not let in: give up on this one (others have their own timers).
                self.waiters.removeValue(forKey: token)?.resume(returning: false)
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
        await ask(["type": "open", "session": id]).map { $0["session"] as? String ?? id }
    }

    /// Fork or rewind a turn on the Mac, then carry on in the session it continues in.
    func turn(_ action: String, _ turn: UInt64, in session: String) async -> Result<String, AskError> {
        let r = await ask(["type": "turn", "session": session, "turn": turn, "action": action])
            .map { $0["session"] as? String ?? session }
        if case .success(let next) = r { requested = next }
        return r
    }

    /// What the Mac did with a model chosen here.
    enum ModelChoice {
        case switched
        case downloading(String)
        /// The project keeps code on your devices unless you say otherwise: ask, then choose
        /// again with the answer ("once" or "always").
        case askCloud(project: String, provider: String)
    }

    /// Use `spec` in a conversation, as the Mac's own picker would: switch, download first, or
    /// say what's in the way.
    func useModel(_ spec: String, in session: String, cloud: String? = nil) async -> Result<ModelChoice, AskError> {
        var m: [String: Any] = ["type": "model", "session": session, "spec": spec]
        if let cloud { m["cloud"] = cloud }
        return await ask(m).map { msg in
            switch msg["result"] as? String {
            case "downloading": .downloading(msg["name"] as? String ?? spec)
            case "ask_cloud": .askCloud(project: msg["project"] as? String ?? "this project", provider: msg["provider"] as? String ?? "the provider")
            default: .switched
            }
        }
    }

    /// The sidebar's row menu: "archive", "unarchive", "pin", "unpin", or "rename" with `title`.
    /// The Mac sends the list back changed.
    func manage(_ session: String, _ action: String, title: String? = nil) {
        var m: [String: Any] = ["type": "manage", "session": session, "action": action]
        if let title { m["title"] = title }
        send(m)
    }

    /// A Mermaid diagram laid out by the Mac's engine.
    func layoutMermaid(_ code: String) async -> Diagram? {
        guard case .success(let msg) = await ask(["type": "mermaid", "code": code, "session": openLink?.session ?? ""]),
              let json = msg["diagram"], let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder.frog.decode(Diagram.self, from: data)
    }

    /// Start a new conversation on the Mac (a chat, or in the folder of `like`) with `text`.
    func startNew(_ text: String, like: String?) async -> Result<String, AskError> {
        var m: [String: Any] = ["type": "new", "text": text]
        if let like { m["like"] = like }
        return await ask(m).map { $0["session"] as? String ?? "" }
    }

    private func ask(_ message: [String: Any]) async -> Result<[String: Any], AskError> {
        await askReply(message).map(\.msg)
    }

    private func askReply(_ message: [String: Any]) async -> Result<Reply, AskError> {
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
    typealias Live = SessionLive

    let id: String
    let title: String
    let folder: String?
    /// The folder's full path on the Mac.
    let cwd: String?
    let model: String
    let modified: Date
    let chat: Bool
    /// Open in a window on the Mac, so it can take messages.
    let open: Bool
    let pinned: Bool
    /// In the Mac's archive.
    let archived: Bool
    let live: Live?
    /// The session as the Mac's sidebar knows it.
    let info: SessionInfo
    /// The step in hand, while it runs.
    let activity: String?
    /// What frog is asking, while it waits.
    let question: Question?

    struct Question: Hashable {
        let id: String
        let name: String
        let arg: String

        /// What frog is asking, as the Mac's card says it.
        var text: String { PermissionRequest.question(name: name, arg: arg) }
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        self.id = id
        title = row["title"] as? String ?? "Untitled"
        folder = row["folder"] as? String
        cwd = row["cwd"] as? String
        model = row["model"] as? String ?? ""
        modified = Date(timeIntervalSince1970: ((row["modified"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        chat = row["chat"] as? Bool ?? false
        open = row["open"] as? Bool ?? false
        pinned = row["pinned"] as? Bool ?? false
        archived = row["archived"] as? Bool ?? false
        live = (row["live"] as? String).flatMap(Live.init)
        activity = row["activity"] as? String
        let decoded = (row["info"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }
        let modifiedMs = Int64((row["modified"] as? NSNumber)?.doubleValue ?? 0)
        info = decoded ?? SessionInfo(id: id, modified: modifiedMs, created: modifiedMs, model: model,
                                      firstInput: nil, title: title, forkedFrom: nil, cwd: cwd)
        question = (row["question"] as? [String: Any]).flatMap { q in
            (q["id"] as? String).map { Question(id: $0, name: q["name"] as? String ?? "", arg: q["arg"] as? String ?? "") }
        }
    }

    /// The model as the Mac names and places it.
    @MainActor
    var identity: ModelIdentity { ModelIdentity.of(model, in: Remote.shared.models) }

    /// Runs on your own hardware (blue), or in the cloud (green), as on the Mac.
    @MainActor
    var isLocal: Bool { !identity.place.isCloud }
}

import Foundation
import Network

/// Lets frog on your iPhone watch this Mac's conversations and answer them: a WebSocket that
/// speaks the engine protocol. Loopback only for now (the iOS simulator reaches it); a LAN and
/// relay transport come with pairing. Every client must say the token first.
///
/// Client → Mac: `hello{token}`, `list`, `attach{session, after}`, `detach{session}`,
/// `op{session, op}` where `op` is an engine `Op` (`submit`, `permission`, `interrupt`, `set_mode`).
/// Mac → client: `welcome{host}`, `sessions{sessions}`, `event{env}` (engine envelopes,
/// verbatim), `synced{session, upto}`, `error{message}`.
///
/// History comes from the session's log, so attaching never disturbs the engine; live events are
/// the engine's own stdout lines, forwarded as they arrive.
@MainActor
final class RemoteBridge {
    static let shared = RemoteBridge()
    static let port: NWEndpoint.Port = 8913

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "remoteEnabled") }
    }

    /// What a client must present. Made once, kept in defaults.
    /// A new code: every paired phone has to pair again.
    static func newToken() {
        UserDefaults.standard.removeObject(forKey: "remoteToken")
        _ = token
    }

    static var token: String {
        if let t = UserDefaults.standard.string(forKey: "remoteToken"), !t.isEmpty { return t }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let t = String((0..<20).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(t, forKey: "remoteToken")
        return t
    }

    private var listener: NWListener?
    private var lanListener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    /// What a newcomer needs that the log doesn't have: the last status and any open question.
    private var live: [String: LiveState] = [:]
    /// A list update is on its way to every phone (changes within 300 ms go as one).
    private var listDue: Task<Void, Never>?

    private struct LiveState {
        var status: String?
        var permission: String?
        var busy = false
        /// The step in hand, in words, for lists and the watch.
        var activity: String?
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        if Self.enabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        // This Mac only (the Simulator), plain.
        let local = Pairing.plain()
        local.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        local.allowLocalEndpointReuse = true
        listener = listen(local, "127.0.0.1:\(Self.port)", lines: false)
        // The local network, encrypted and keyed by the code, found by Bonjour.
        let lan = Pairing.parameters(code: Self.token)
        lan.requiredLocalEndpoint = .hostPort(host: .ipv6(.any), port: Pairing.lanPort)
        lan.allowLocalEndpointReuse = true
        lanListener = listen(lan, "the network on \(Pairing.lanPort)", lines: true, service: .init(name: Self.name, type: Pairing.service))
    }

    /// This Mac's name, as phones see it.
    static var name: String { Host.current().localizedName ?? "Mac" }

    /// Where a phone on the network reaches this Mac, for the QR code: its Bonjour host name.
    static var lanHost: String {
        let local = ProcessInfo.processInfo.hostName
        let host = local.hasSuffix(".local") ? local : local.split(separator: ".").first.map { "\($0).local" } ?? local
        return "\(host):\(Pairing.lanPort)"
    }

    static var pairingURL: URL { Pairing.url(name: name, host: lanHost, code: token) }

    private func listen(_ params: NWParameters, _ label: String, lines: Bool, service: NWListener.Service? = nil) -> NWListener? {
        do {
            let l = try NWListener(using: params)
            l.service = service
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn, lines: lines) }
            }
            l.stateUpdateHandler = { state in
                EngineProcess.log("remote: listener on \(label): \(state)")
            }
            l.serviceRegistrationUpdateHandler = { change in
                if case .add(let endpoint) = change { EngineProcess.log("remote: advertised as \(endpoint)") }
            }
            l.start(queue: .main)
            EngineProcess.log("remote: listening on \(label)")
            return l
        } catch {
            EngineProcess.log("remote: couldn't listen on \(label): \(error)")
            return nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lanListener?.cancel()
        lanListener = nil
        clients.values.forEach { $0.conn.cancel() }
        clients = [:]
    }

    // MARK: Engine lines

    /// Every line an engine prints. Called from `EngineProcess`, before the app folds it in.
    func forward(_ line: String) {
        guard listener != nil, let head = Head(line) else { return }
        track(head, line)
        RemotePush.shared.observe(line)
        if ["turn_started", "turn_ended", "idle", "permission_request", "permission_resolved", "item_started", "titled"]
            .contains(head.event) { listChanged() }
        for c in clients.values where c.attached.keys.contains(head.session) {
            c.deliver(line, head: head)
        }
    }

    /// Tell every phone what changed in the list, soon: they no longer ask every few seconds.
    func listChanged() {
        guard listener != nil, listDue == nil else { return }
        listDue = Task {
            try? await Task.sleep(for: .milliseconds(300))
            listDue = nil
            let rows = sessionList()
            for c in clients.values where c.authed { c.send(["type": "sessions", "sessions": rows]) }
        }
    }

    private func track(_ head: Head, _ line: String) {
        var s = live[head.session] ?? LiveState()
        switch head.event {
        case "status": s.status = line
        case "permission_request": s.permission = line
        case "permission_resolved", "turn_ended": s.permission = nil
        case "turn_started": s.busy = true; s.activity = "Thinking"
        case "idle": s.busy = false; s.permission = nil; s.activity = nil
        case "item_started":
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let kind = obj["kind"] as? [String: Any] {
                s.activity = kind["type"] as? String == "tool_call"
                    ? RemotePush.verb(kind["name"] as? String ?? "", kind["arg"] as? String ?? "")
                    : kind["type"] as? String == "message" ? "Writing the answer" : "Thinking"
            }
        default: break
        }
        live[head.session] = s
    }

    // MARK: Clients

    private func accept(_ conn: NWConnection, lines: Bool) {
        let client = Client(conn: conn, lines: lines)
        clients[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            if case .failed(let e) = state { EngineProcess.log("remote: a phone's connection failed: \(e)") }
            if case .waiting(let e) = state { EngineProcess.log("remote: a phone's connection is waiting: \(e)") }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in if let client { self?.clients[ObjectIdentifier(client)] = nil } }
            default: break
            }
        }
        conn.start(queue: .main)
        receive(client)
    }

    private func receive(_ client: Client) {
        if let splitter = client.splitter {
            // The network: JSON lines over TLS.
            client.conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak client] data, _, done, error in
                Task { @MainActor in
                    guard let self, let client else { return }
                    for line in data.map(splitter.push) ?? [] {
                        if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.handle(msg, from: client) }
                    }
                    if error == nil, !done { self.receive(client) } else { client.conn.cancel() }
                }
            }
            return
        }
        client.conn.receiveMessage { [weak self, weak client] data, _, _, error in
            Task { @MainActor in
                guard let self, let client else { return }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(msg, from: client)
                }
                if error == nil { self.receive(client) } else { client.conn.cancel() }
            }
        }
    }

    private func handle(_ msg: [String: Any], from client: Client) {
        let type = msg["type"] as? String ?? ""
        guard client.authed || type == "hello" else {
            client.send(["type": "error", "message": "say hello first"])
            return client.conn.cancel()
        }
        switch type {
        case "hello":
            guard let t = msg["token"] as? String, Self.matches(t, Self.token) else {
                client.send(["type": "error", "message": "wrong code"])
                return client.conn.cancel()
            }
            client.authed = true
            client.send(["type": "welcome", "host": Host.current().localizedName ?? "Mac"])
        case "list":
            client.send(["type": "sessions", "sessions": sessionList()])
        case "attach":
            guard let id = msg["session"] as? String else { return }
            attach(client, to: id, after: (msg["after"] as? NSNumber)?.uint64Value ?? 0)
        case "register":
            // Where to reach this phone when it's asleep.
            guard let transport = msg["transport"] as? String, let address = msg["address"] as? String,
                  let bundle = msg["bundle"] as? String else { return }
            RemotePush.shared.register(.init(transport: transport, address: address, bundle: bundle, env: msg["env"] as? String))
            client.address = address
        case "activity":
            guard let id = msg["session"] as? String, let address = client.address else { return }
            RemotePush.shared.activity(session: id, token: msg["token"] as? String, device: address)
        case "open":
            // Resume a conversation in a window, so the phone can talk to it.
            guard let id = msg["session"] as? String else { return }
            if Library.shared.conversation(id) != nil { return client.send(["type": "opened", "session": id, "ref": msg["ref"] ?? ""]) }
            guard let s = Library.shared.sessions.first(where: { $0.id == id }) else {
                return client.send(["type": "error", "session": id, "message": "That conversation isn't on this Mac anymore."])
            }
            request(OpenRequest(session: s, folder: nil, text: nil), for: client, ref: msg["ref"])
        case "new":
            // A new conversation: a chat, or in the folder of the one named by `like`.
            let like = (msg["like"] as? String).flatMap { id in Library.shared.sessions.first { $0.id == id } }
            let folder = like.flatMap { $0.isChat ? nil : $0.folder }
            request(OpenRequest(session: nil, folder: folder, text: msg["text"] as? String), for: client, ref: msg["ref"])
        case "detach":
            if let id = msg["session"] as? String { client.attached[id] = nil }
        case "op":
            guard let id = msg["session"] as? String, let op = msg["op"] as? [String: Any] else { return }
            perform(op, in: id, for: client)
        default:
            client.send(["type": "error", "message": "unknown message \(type)"])
        }
    }

    /// Ask a window to open a conversation (whichever window claims it), then tell the phone
    /// its session once the engine has one.
    private func request(_ r: OpenRequest, for client: Client, ref: Any?) {
        let ref = ref ?? ""
        r.done = { [weak client] c in
            Task { @MainActor in
                // A fresh conversation learns its session from the engine's first event.
                for _ in 0..<100 {
                    if let id = c?.sessionID {
                        client?.send(["type": "opened", "session": id, "ref": ref])
                        // The engine writes a new session's file with its first message; list it
                        // once that's on disk, so the phone can find it before the turn ends.
                        try? await Task.sleep(for: .seconds(1))
                        Library.shared.refresh()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                client?.send(["type": "error", "ref": ref, "message": "frog on your Mac didn't open it in time."])
            }
        }
        NotificationCenter.default.post(name: OpenRequest.name, object: r)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !r.claimed {
                client.send(["type": "error", "ref": ref, "message": "Open a frog window on your Mac first."])
            }
        }
    }

    /// Constant-time comparison, so the code can't be guessed a character at a time.
    private static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func sessionList() -> [[String: Any]] {
        let lib = Library.shared
        return lib.sessions.filter { !lib.archived.contains($0.id) }.prefix(200).map { s in
            let c = lib.conversation(s.id)
            var row: [String: Any] = [
                "id": s.id, "title": s.displayTitle, "modified": s.modified, "model": s.model,
                "chat": s.isChat, "open": c != nil, "pinned": lib.pinned.contains(s.id),
            ]
            if let cwd = s.cwd { row["folder"] = (cwd as NSString).lastPathComponent }
            switch lib.live[s.id] {
            case .running: row["live"] = "running"
            case .waiting: row["live"] = "waiting"
            case .unread: row["live"] = "unread"
            case nil: break
            }
            if let state = live[s.id] {
                if let a = state.activity { row["activity"] = a }
                // The open question, so a list or a watch can answer it without the thread.
                if let line = state.permission,
                   let q = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    row["question"] = ["id": q["id"] ?? "", "name": q["name"] ?? "", "arg": String((q["arg"] as? String ?? "").prefix(200))]
                }
            }
            return row
        }
    }

    /// History from the log, then what's live. Lines that arrive meanwhile wait in the client's
    /// buffer, and any the log already covered are dropped.
    private func attach(_ client: Client, to id: String, after: UInt64) {
        client.attached[id] = .replaying([])
        let log = Frog.sessions.appending(path: "\(id).jsonl")
        Task.detached {
            let lines = Self.durable(in: log, after: after)
            await MainActor.run {
                for l in lines.events { client.sendRaw(#"{"type":"event","env":"# + l + "}") }
                client.send(["type": "synced", "session": id, "upto": lines.upto])
                let state = self.live[id]
                let buffered: [(Head, String)]
                if case .replaying(let b) = client.attached[id] { buffered = b } else { buffered = [] }
                client.attached[id] = .live(upto: lines.upto)
                for l in [state?.status, state?.permission].compactMap({ $0 }) {
                    client.sendRaw(#"{"type":"event","env":"# + l + "}")
                }
                for (head, line) in buffered { client.deliver(line, head: head) }
            }
        }
    }

    /// The durable envelopes in a session log with `seq > after`, as JSON strings.
    private nonisolated static func durable(in log: URL, after: UInt64) -> (events: [String], upto: UInt64) {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return ([], after) }
        var events: [String] = []
        var upto = after
        for line in text.split(separator: "\n") {
            guard line.contains(#""type":"event""#),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let env = obj["env"] as? [String: Any],
                  let seq = (env["seq"] as? NSNumber)?.uint64Value, seq > after,
                  let data = try? JSONSerialization.data(withJSONObject: env) else { continue }
            events.append(String(decoding: data, as: UTF8.self))
            upto = max(upto, seq)
        }
        return (events, upto)
    }

    private func perform(_ op: [String: Any], in id: String, for client: Client) {
        guard let c = Library.shared.conversation(id) else {
            return client.send(["type": "error", "session": id, "message": "Open this conversation on your Mac to talk to it."])
        }
        switch op["op"] as? String {
        case "submit":
            // Images too: a screenshot shared from the phone goes in with the message.
            let images = (op["images"] as? [[String: String]] ?? []).compactMap { i in
                i["mime"].flatMap { m in i["data"].map { ToolImage(mime: m, data: $0) } }
            }
            c.submit(op["text"] as? String ?? "", images: images)
        case "permission":
            guard let pid = op["id"] as? String, c.permission?.id == pid,
                  let d = (op["decision"] as? String).flatMap(Decision.init(rawValue:)) else { return }
            c.answer(d)
        case "interrupt":
            c.interrupt()
        case "set_mode":
            if let m = (op["mode"] as? String).flatMap(Mode.init(rawValue:)) { c.setMode(m) }
        default:
            client.send(["type": "error", "session": id, "message": "Not supported from the phone yet."])
        }
    }
}

/// A phone asking for a conversation on this Mac: an existing one to resume, or a new one (in
/// `folder`, or a chat) that starts with `text`. The first window to claim it opens it.
@MainActor
final class OpenRequest {
    static let name = Notification.Name("eco.frog.remote.open")

    let session: SessionInfo?
    let folder: URL?
    let text: String?
    private(set) var claimed = false
    var done: (Conversation?) -> Void = { _ in }

    init(session: SessionInfo?, folder: URL?, text: String?) {
        self.session = session
        self.folder = folder
        self.text = text
    }

    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

enum Handoff {
    /// A conversation being read on one device, for another to pick up.
    static let conversation = "eco.frog.conversation"
}

/// The routing fields of an envelope line, without decoding the rest.
private struct Head {
    let session: String
    let seq: UInt64
    let event: String

    init?(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let session = obj["session"] as? String else { return nil }
        self.session = session
        seq = (obj["seq"] as? NSNumber)?.uint64Value ?? 0
        event = obj["event"] as? String ?? ""
    }
}

@MainActor
private final class Client {
    enum Attachment {
        case replaying([(Head, String)])
        case live(upto: UInt64)
    }

    let conn: NWConnection
    var authed = false
    /// The phone's push address, once it has registered.
    var address: String?
    var attached: [String: Attachment] = [:]

    /// Set for network clients, whose messages are JSON lines rather than WebSocket frames.
    let splitter: Pairing.Lines?

    init(conn: NWConnection, lines: Bool) {
        self.conn = conn
        splitter = lines ? Pairing.Lines() : nil
    }

    func deliver(_ line: String, head: Head) {
        switch attached[head.session] {
        case .replaying(var buffer):
            buffer.append((head, line))
            attached[head.session] = .replaying(buffer)
        case .live(let upto):
            // Already sent from the log.
            if head.seq != 0, head.seq <= upto { return }
            sendRaw(#"{"type":"event","env":"# + line + "}")
        case nil:
            break
        }
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        sendRaw(String(decoding: data, as: UTF8.self))
    }

    func sendRaw(_ text: String) {
        if splitter != nil {
            conn.send(content: Data((text + "\n").utf8), completion: .idempotent)
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}

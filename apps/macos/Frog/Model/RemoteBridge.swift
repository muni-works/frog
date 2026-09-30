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
    static var token: String {
        if let t = UserDefaults.standard.string(forKey: "remoteToken"), !t.isEmpty { return t }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let t = String((0..<20).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(t, forKey: "remoteToken")
        return t
    }

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    /// What a newcomer needs that the log doesn't have: the last status and any open question.
    private var live: [String: LiveState] = [:]

    private struct LiveState {
        var status: String?
        var permission: String?
        var busy = false
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        if Self.enabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 << 20
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { EngineProcess.log("remote: listener failed: \(e)") }
            }
            l.start(queue: .main)
            listener = l
            EngineProcess.log("remote: listening on 127.0.0.1:\(Self.port)")
        } catch {
            EngineProcess.log("remote: couldn't listen: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.conn.cancel() }
        clients = [:]
    }

    // MARK: Engine lines

    /// Every line an engine prints. Called from `EngineProcess`, before the app folds it in.
    func forward(_ line: String) {
        guard listener != nil, let head = Head(line) else { return }
        track(head, line)
        for c in clients.values where c.attached.keys.contains(head.session) {
            c.deliver(line, head: head)
        }
    }

    private func track(_ head: Head, _ line: String) {
        var s = live[head.session] ?? LiveState()
        switch head.event {
        case "status": s.status = line
        case "permission_request": s.permission = line
        case "permission_resolved", "turn_ended": s.permission = nil
        case "turn_started": s.busy = true
        case "idle": s.busy = false; s.permission = nil
        default: break
        }
        live[head.session] = s
    }

    // MARK: Clients

    private func accept(_ conn: NWConnection) {
        let client = Client(conn: conn)
        clients[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
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
        case "detach":
            if let id = msg["session"] as? String { client.attached[id] = nil }
        case "op":
            guard let id = msg["session"] as? String, let op = msg["op"] as? [String: Any] else { return }
            perform(op, in: id, for: client)
        default:
            client.send(["type": "error", "message": "unknown message \(type)"])
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
            if let text = op["text"] as? String { c.submit(text) }
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
    var attached: [String: Attachment] = [:]

    init(conn: NWConnection) { self.conn = conn }

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
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}

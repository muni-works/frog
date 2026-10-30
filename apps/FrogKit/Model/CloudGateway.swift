import Foundation

/// Frog Cloud's gateway (the web app's `cloud/client.ts`): sessions that run in their own
/// sandbox, listed and made over REST, streamed over a websocket that speaks the same
/// protocol as `frog --serve`. So a cloud session is a `Conversation` with a `CloudLink`.
struct CloudGateway: Sendable {
    /// `FROG_GATEWAY` points it elsewhere, such as a local zest gateway (`dev/run.sh`).
    static let origin = ProcessInfo.processInfo.environment["FROG_GATEWAY"].flatMap(URL.init(string:)) ?? URL(string: "https://api.frog.toys")!
    static let protocolVersion = 1
    static let client = "frog-mac/0.1.0"

    let token: String

    struct Session: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
        let repo: String
        let branch: String
        let state: String
        let created: Double?
        let updated: Double
        let last_turn: Double?
        let archived: Bool?
        let pr: String?
        let error: String?
    }

    struct Repos: Decodable, Sendable {
        struct Repo: Decodable, Hashable, Sendable { let name: String; let `private`: Bool }
        let repos: [Repo]
        let install: String?
    }

    private struct List: Decodable { let sessions: [Session] }

    func sessions() async throws -> [Session] { try await req(List.self, "GET", "v1/sessions").sessions }
    func repos() async throws -> Repos { try await req(Repos.self, "GET", "v1/repos") }
    func create(repo: String?, model: String?) async throws -> Session {
        var body: [String: String] = [:]
        if let repo { body["repo"] = repo }
        if let model { body["model"] = model }
        return try await req(Session.self, "POST", "v1/sessions", body)
    }
    func archive(_ id: String, _ archived: Bool) async throws {
        _ = try await req(Session.self, "PATCH", "v1/sessions/\(id)", ["archived": archived])
    }
    func remove(_ id: String) async throws {
        var r = request("DELETE", "v1/sessions/\(id)")
        r.httpBody = nil
        _ = try check(await URLSession.shared.data(for: r))
    }

    func wsURL(_ id: String) -> URL {
        var u = URLComponents(url: Self.origin.appending(path: "v1/sessions/\(id)/ws"), resolvingAgainstBaseURL: false)!
        u.scheme = u.scheme == "http" ? "ws" : "wss"
        return u.url!
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var r = URLRequest(url: Self.origin.appending(path: path), timeoutInterval: 30)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func req<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> T {
        var r = request(method, path)
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try JSONDecoder().decode(T.self, from: check(await URLSession.shared.data(for: r)))
    }

    private func check(_ result: (Data, URLResponse)) throws -> Data {
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GatewayError(status: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    struct GatewayError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }
}

/// A cloud session's engine, through the gateway's websocket: the `hello`/`welcome`
/// handshake, then envelopes in and ops out. It reconnects with `resume_after` (backing off
/// to 10 s) until stopped, refused (4001) or the session is deleted (4004).
@MainActor
final class CloudLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var endDescription = ""
    private(set) var isAlive = true
    /// What the composer's corner says: nil when live.
    private(set) var connection: String? = "Connecting…"

    private let gateway: CloudGateway
    private let id: String
    private var lastSeq: UInt64
    private var task: URLSessionWebSocketTask?
    private var live = false
    private var stopped = false
    private var attempt = 0
    private var queue: [Data] = []
    /// The replay ends at the welcome's `last_seq`. `frog --serve` says `idle` when it's ready;
    /// the gateway doesn't, so the link says it once caught up, unless a turn is still open.
    private var caughtUpAt: UInt64?
    private var openTurn = false
    private var lastCreated: Int64 = 0
    /// Per engine (its session id), how far its turn numbers are shifted; see `take`.
    private var turnOffset: [String: Int] = [:]
    private var maxTurn = 0
    private let encoder = JSONEncoder()

    init(gateway: CloudGateway, session: String, after: UInt64 = 0) {
        self.gateway = gateway
        id = session
        lastSeq = after
        open()
        // As on the web: questions get a card; a preview pane would need the sandbox's network.
        send(.setClientCaps(panes: false, ask: true))
    }

    func send(_ op: Op) {
        guard let data = try? encoder.encode(op) else { return }
        if live, let task { task.send(.string(String(decoding: data, as: UTF8.self))) { _ in } } else { queue.append(data) }
    }

    func stop() {
        stopped = true
        task?.cancel(with: .normalClosure, reason: nil)
        end("Disconnected")
    }

    private func end(_ why: String) {
        guard isAlive else { return }
        isAlive = false
        endDescription = why
        connection = why
        onEvent(nil)
    }

    private func open() {
        var r = URLRequest(url: gateway.wsURL(id))
        r.setValue("frog, bearer.\(gateway.token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        r.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: r)
        self.task = task
        live = false
        connection = attempt == 0 ? "Connecting…" : "Reconnecting…"
        task.resume()
        let hello: [String: Any] = ["hello": ["protocol": CloudGateway.protocolVersion, "client": CloudGateway.client, "resume_after": lastSeq]]
        if let data = try? JSONSerialization.data(withJSONObject: hello) {
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.take(Data(s.utf8))
                    case .data(let d): self.take(d)
                    @unknown default: break
                    }
                    self.receive(task)
                case .failure:
                    self.closed(Int(task.closeCode.rawValue))
                }
            }
        }
    }

    private func take(_ data: Data) {
        guard !live else {
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let event = object?["event"] as? String
            // A sandbox woken from its sleep snapshot runs a new engine (a new session id in
            // its envelopes) that numbers turns from 1 again: shift its turns past the last
            // engine's, so its first turn is a new one rather than folded into turn 1.
            var data = data
            if let engine = object?["session"] as? String, let turn = (object?["turn"] as? NSNumber)?.intValue {
                if turnOffset[engine] == nil { turnOffset[engine] = turnOffset.isEmpty ? 0 : maxTurn }
                let shifted = turn + (turnOffset[engine] ?? 0)
                maxTurn = max(maxTurn, shifted)
                if shifted != turn {
                    object?["turn"] = shifted
                    if let o = object, let d = try? JSONSerialization.data(withJSONObject: o) { data = d }
                }
            }
            if event == "turn_started" { openTurn = true }
            if event == "turn_ended" || event == "idle" { openTurn = false }
            let decoded: Envelope?
            do { decoded = try JSONDecoder.frog.decode(Envelope.self, from: data) } catch {
                decoded = nil
                FileHandle.standardError.write(Data("cloud: skipped \(event ?? "?"): \(error)\n".utf8))
            }
            // Replay after a reconnect can overlap what we already have. A sandbox woken from
            // its sleep snapshot runs a new engine whose seqs restart low (until ecto/frog#154),
            // so, as on the web, newer in time beats seq.
            if let env = decoded, env.seq > lastSeq || env.created > lastCreated {
                lastSeq = max(lastSeq, env.seq)
                lastCreated = max(lastCreated, env.created)
                onEvent(env)
            }
            catchUp()
            return
        }
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let refused = v?["refused"] as? [String: Any] {
            stopped = true
            end("Update Frog to continue (\(refused["reason"] as? String ?? "protocol"))")
            return
        }
        guard let welcome = v?["welcome"] as? [String: Any] else { return }
        caughtUpAt = (welcome["last_seq"] as? NSNumber)?.uint64Value ?? 0
        live = true
        attempt = 0
        connection = nil
        for d in queue { task?.send(.string(String(decoding: d, as: UTF8.self))) { _ in } }
        queue.removeAll()
        catchUp()
    }

    private func catchUp() {
        guard let at = caughtUpAt, lastSeq >= at else { return }
        caughtUpAt = nil
        guard !openTurn else { return }
        let idle = #"{"seq":\#(lastSeq),"session":"\#(id)","created":0,"event":"idle"}"#
        if let env = try? JSONDecoder().decode(Envelope.self, from: Data(idle.utf8)) { onEvent(env) }
    }

    private func closed(_ code: Int) {
        task = nil
        live = false
        guard !stopped, isAlive else { return }
        if code == 4001 { return end("Update Frog to continue") }
        if code == 4004 { return end("Session deleted") }
        attempt += 1
        connection = "Reconnecting…"
        let delay = min(0.25 * pow(2, Double(attempt - 1)), 10)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !self.stopped { self.open() }
        }
    }
}

extension CloudLink {
    /// Rename a cloud session as the web does: `set_title` to its engine, whose `titled`
    /// event renames it everywhere. A short-lived link when the session isn't open here.
    static func rename(_ id: String, to title: String, gateway: CloudGateway) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let link = CloudLink(gateway: gateway, session: id)
        link.send(.setTitle(t))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))  // a sleeping sandbox wakes first
            link.stop()
        }
    }
}

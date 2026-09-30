import Foundation
import Observation

/// The connection to frog on your Mac (`RemoteBridge` there): one WebSocket, the session list,
/// and the conversation you're looking at. Reconnects on its own, and picks a conversation up
/// from the last event it saw, so nothing arrives twice and nothing is missed.
@MainActor
@Observable
final class Remote {
    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var sessions: [RemoteSession] = []
    private(set) var open: SessionModel?

    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "remoteHost") }
    }
    var code: String {
        didSet { UserDefaults.standard.set(code, forKey: "remoteCode") }
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init() {
        let env = ProcessInfo.processInfo.environment
        host = env["FROG_REMOTE_HOST"] ?? UserDefaults.standard.string(forKey: "remoteHost") ?? "127.0.0.1:8913"
        code = env["FROG_REMOTE_CODE"] ?? UserDefaults.standard.string(forKey: "remoteCode") ?? ""
    }

    var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    // MARK: Connection

    func connect() {
        retry?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        guard !code.isEmpty, let url = URL(string: "ws://\(host)") else {
            state = .failed("Enter the code from Frog's settings on your Mac.")
            return
        }
        generation += 1
        let gen = generation
        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        send(["type": "hello", "token": code])
        receive(task, gen)
    }

    func disconnect() {
        retry?.cancel()
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .idle
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(Data(s.utf8))
                    case .data(let d): self.handle(d)
                    @unknown default: break
                    }
                    self.receive(task, gen)
                case .failure(let error):
                    self.lost(error.localizedDescription, gen)
                }
            }
        }
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
            refresh()
            // Back after a drop: carry on where the transcript left off.
            if let open { send(["type": "attach", "session": open.id, "after": open.lastSeq]) }
        case "sessions":
            let rows = msg["sessions"] as? [[String: Any]] ?? []
            sessions = rows.compactMap(RemoteSession.init)
            open?.isOpenOnMac = sessions.first { $0.id == open?.id }?.open ?? false
        case "event":
            guard let env = msg["env"],
                  let raw = try? JSONSerialization.data(withJSONObject: env),
                  let envelope = try? JSONDecoder.frog.decode(Envelope.self, from: raw),
                  envelope.session == open?.id else { return }
            open?.apply(envelope)
        case "synced":
            if (msg["session"] as? String) == open?.id { open?.synced() }
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
        let model = SessionModel(session: session, remote: self)
        open = model
        send(["type": "attach", "session": session.id, "after": 0])
        return model
    }

    func detach(_ model: SessionModel) {
        guard open === model else { return }
        send(["type": "detach", "session": model.id])
        open = nil
    }

    func send(op: [String: Any], in session: String) {
        send(["type": "op", "session": session, "op": op])
    }

    private func send(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
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

/// Stand-ins for the Mac-only helpers that the shared protocol file refers to.
enum Frog {
    static func isChat(_ url: URL) -> Bool { url.path.hasSuffix("/.local/share/frog/chat") }
}

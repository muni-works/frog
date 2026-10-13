import Foundation

/// The watch reaching the Mac on its own, for when the phone is dead or in another room: a
/// WebSocket to frog's bridge, at a `wss://` URL the phone handed over (say, `tailscale serve` in
/// front of the Mac's 127.0.0.1:8913), presenting the pairing code as its token. watchOS keeps
/// apps off raw sockets, so this is URLSession, not the phone's TLS-PSK over Bonjour.
@MainActor
final class WatchBridge {
    enum State: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .off
    var onState: (State) -> Void = { _ in }
    var onRows: ([Snapshot.Row]) -> Void = { _ in }

    private var task: URLSessionWebSocketTask?
    private var target: (url: URL, code: String)?
    private var generation = 0
    private var retry: Task<Void, Never>?

    var isConnected: Bool { state == .connected }

    func connect(url: URL, code: String) {
        if let target, target.url == url, target.code == code, state == .connected || state == .connecting { return }
        target = (url, code)
        open()
    }

    func disconnect() {
        target = nil
        close()
        set(.off)
    }

    private func open() {
        close()
        guard let target else { return }
        generation += 1
        let gen = generation
        let t = URLSession.shared.webSocketTask(with: target.url)
        task = t
        set(.connecting)
        t.resume()
        send(["type": "hello", "token": target.code])
        Task { await self.receive(t, gen) }
    }

    private func close() {
        retry?.cancel()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) async {
        while gen == generation {
            do {
                let message = try await t.receive()
                guard gen == generation else { return }
                switch message {
                case .string(let s): handle(Data(s.utf8))
                case .data(let d): handle(d)
                @unknown default: break
                }
            } catch {
                guard gen == generation else { return }
                lost(error.localizedDescription)
                return
            }
        }
    }

    /// Dropped: try again in a bit, unless the Mac turned us away.
    private func lost(_ why: String) {
        task = nil
        set(.failed("Can't reach your Mac"))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.target != nil else { return }
            self.open()
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["type"] as? String {
        case "welcome":
            set(.connected)
            send(["type": "list"])
        case "sessions":
            let rows = (msg["sessions"] as? [[String: Any]] ?? []).compactMap(Snapshot.Row.init(bridge:))
                .filter { ["waiting", "running", "unread"].contains($0.live) }
            onRows(Array(rows.prefix(12)))
        case "error" where msg["ref"] == nil && msg["session"] == nil:
            // Turned away (the wrong code): don't keep knocking.
            close()
            set(.failed(msg["message"] as? String == "wrong code" ? "Pair your phone again" : "Your Mac said no"))
        default:
            break
        }
    }

    /// Do something on the Mac: connect if we must and wait to be let in. False if we couldn't.
    func perform(op: [String: Any], in session: String) async -> Bool {
        if !isConnected {
            guard target != nil else { return false }
            if state != .connecting { open() }
            for _ in 0..<30 where !isConnected {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard isConnected else { return false }
        }
        send(["type": "op", "session": session, "op": op])
        try? await Task.sleep(for: .milliseconds(300))
        send(["type": "list"])
        return true
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        onState(s)
    }
}

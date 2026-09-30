import Foundation

/// One errand to the Mac for an extension (the share sheet): connect, say the code, send, close.
/// The app itself uses `Remote`; this is the part an extension can afford.
enum QuickLink {
    enum Failure: Error { case notPaired, unreachable, refused(String) }

    /// Send `op` to `session` on the Mac the app is paired with.
    static func send(_ op: [String: Any], to session: String) async throws {
        guard let (host, code) = Snapshot.connection, let url = URL(string: "ws://\(host)") else { throw Failure.notPaired }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 32 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string(json(["type": "hello", "token": code])))
        // Let in, or turned away.
        let reply = try await withTimeout(6) { try await socket.receive() }
        guard case .string(let s) = reply,
              let msg = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { throw Failure.unreachable }
        guard msg["type"] as? String == "welcome" else { throw Failure.refused(msg["message"] as? String ?? "refused") }
        try await socket.send(.string(json(["type": "op", "session": session, "op": op])))
        // A moment for it to land before we hang up.
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure.unreachable
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

import Foundation
import Network

/// One errand to the Mac for an extension (the share sheet): connect, say the code, send, close.
/// The app itself uses `Remote`; this is the part an extension can afford.
enum QuickLink {
    enum Failure: Error { case notPaired, unreachable, refused(String) }

    /// Send `op` to `session` on the Mac the app is paired with.
    static func send(_ op: [String: Any], to session: String) async throws {
        guard let (host, code) = Snapshot.connection else { throw Failure.notPaired }
        let hello = json(["type": "hello", "token": code])
        let message = json(["type": "op", "session": session, "op": op])
        let socket = BridgeSocket(host: host, code: code)
        let result: Result<Void, Failure> = await withCheckedContinuation { cont in
            let once = Once(cont)
            socket.onReady = { socket.send(hello) }
            socket.onMessage = { data in
                let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard msg?["type"] as? String == "welcome" else {
                    return once.resume(.failure(.refused(msg?["message"] as? String ?? "refused")))
                }
                socket.send(message)
                // A moment for it to land before we hang up.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { once.resume(.success(())) }
            }
            socket.onClose = { _, _ in once.resume(.failure(.unreachable)) }
            socket.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.resume(.failure(.unreachable)) }
        }
        socket.cancel()
        try result.get()
    }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Resumes its continuation the first time only.
    private final class Once: @unchecked Sendable {
        private var cont: CheckedContinuation<Result<Void, Failure>, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Result<Void, Failure>, Never>) { cont = c }
        func resume(_ r: Result<Void, Failure>) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: r)
        }
    }
}

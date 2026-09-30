import Foundation
import WatchConnectivity

/// The watch's view of the Mac, through the phone: what needs you and what's running, sent as
/// the watch's application context whenever the list changes; the watch's answers come back as
/// messages and go to the Mac like any other.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private var last: [[String: String]] = []

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func share(_ sessions: [RemoteSession]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let rows: [[String: String]] = sessions.filter { $0.live == .waiting || $0.live == .running }.prefix(12).map { s in
            var row = ["id": s.id, "title": s.title, "live": s.live?.rawValue ?? ""]
            if let a = s.activity { row["activity"] = a }
            if let q = s.question { row["question"] = q.text; row["permission"] = q.id }
            return row
        }
        guard rows != last else { return }
        last = rows
        try? WCSession.default.updateApplicationContext(["sessions": rows, "at": Date().timeIntervalSince1970])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// An answer from the wrist.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let replyHandler = replyHandler
        let id = message["session"] as? String
        let permission = message["permission"] as? String
        let allow = message["allow"] as? Bool ?? false
        Task { @MainActor in
            guard let id, let permission else { return replyHandler(["ok": false]) }
            if let player = FixturePlayer.playing[id] {
                player.send(op: ["op": "permission", "id": permission, "decision": allow ? "allow" : "deny"], in: id)
                return replyHandler(["ok": true])
            }
            let sent = await Remote.shared.perform(op: ["op": "permission", "id": permission, "decision": allow ? "allow" : "deny"], in: id)
            replyHandler(["ok": sent])
            Remote.shared.refresh()
        }
    }
}

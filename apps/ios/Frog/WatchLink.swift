import Foundation
import WatchConnectivity

/// The watch's view of the Mac, through the phone: what needs you and what's running, sent as
/// the watch's application context whenever the list changes, with how to reach the Mac without
/// the phone (`direct`, and the code). The watch's answers come back as messages and go to the
/// Mac like any other.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    /// Where the watch reaches the Mac when the phone isn't around: a `wss://` URL that ends at
    /// the Mac's bridge (say, `tailscale serve` in front of 127.0.0.1:8913). Set in Settings.
    static let directKey = "watchDirectURL"
    private var last: Data?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func share(_ sessions: [RemoteSession]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let rows = sessions.filter { $0.live == .waiting || $0.live == .running || $0.live == .unread }.prefix(12).map { s in
            Snapshot.Row(id: s.id, title: s.title, live: s.live?.rawValue ?? "", activity: s.activity,
                         question: s.question?.text, permission: s.question?.id, local: s.isLocal,
                         arg: s.question.map { Snapshot.Row.what(name: $0.name, arg: $0.arg) },
                         reason: s.question?.reason, always: s.question?.always, change: s.question?.change,
                         since: s.since, open: s.open,
                         ask: s.ask, last: s.last.map { String($0.prefix(1200)) },
                         stats: s.stats, actions: s.actions)
        }
        guard let data = try? JSONEncoder().encode(Array(rows)) else { return }
        let direct = UserDefaults.standard.string(forKey: Self.directKey) ?? ""
        let blob = data + Data(direct.utf8)
        guard blob != last else { return }
        last = blob
        var context: [String: Any] = ["rows": data, "at": Date().timeIntervalSince1970]
        if !direct.isEmpty, !Remote.shared.code.isEmpty {
            context["direct"] = direct
            context["code"] = Remote.shared.code
        }
        try? WCSession.default.updateApplicationContext(context)
    }

    /// Settings changed how the watch reaches the Mac: tell it now.
    func directChanged() {
        last = nil
        share(Remote.shared.sessions)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// "Show me this on the phone": a long press on what frog said, on the wrist.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let id = message["show"] as? String else { return }
        Task { @MainActor in Remote.shared.requested = id }
    }

    /// An answer from the wrist: `op` is an engine op (a permission, or an Ask's answer).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let replyHandler = replyHandler
        nonisolated(unsafe) let op = message["op"] as? [String: Any]
        let id = message["session"] as? String
        Task { @MainActor in
            guard let id, let op else { return replyHandler(["ok": false]) }
            if let player = FixturePlayer.playing[id], op["op"] as? String == "permission",
               let pid = op["id"] as? String {
                player.send(.permission(id: pid, decision: op["decision"] as? String == "allow" ? .allow : .deny))
                return replyHandler(["ok": true])
            }
            let sent = await Remote.shared.perform(op: op, in: id)
            replyHandler(["ok": sent])
            Remote.shared.refresh()
        }
    }
}

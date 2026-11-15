import Foundation

/// The graceful-restart half of an update (docs/design/graceful-restart.md). Off by default;
/// when the user turns it on, an update first asks every running engine to stop at a safe
/// point (`Op::Drain`), waits for all of them inside one shared budget, records the resume
/// manifest, and only then lets Sparkle replace the bundle and relaunch. Engines that miss
/// the deadline are killed and their turns resume as a crash would — never worse than the
/// old path. Only app-spawned engines drain; CLI workers live outside the bundle and keep
/// running untouched.
@MainActor
enum UpdateDrain {
    static let key = "gracefulUpdates"
    /// The shared drain budget, seconds (a setting, 5–120).
    static let budgetKey = "gracefulUpdateBudget"

    /// Opt-in: default off for everyone; the manager fleet turns it on.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var budget: Double {
        get {
            let v = UserDefaults.standard.double(forKey: budgetKey)
            return v == 0 ? 20 : min(max(v, 5), 120)
        }
        set { UserDefaults.standard.set(min(max(newValue, 5), 120), forKey: budgetKey) }
    }

    /// Drain every open conversation inside the shared budget, then force-kill whatever
    /// didn't stop in time. Every engine gets its `Drain` at once (the op is sent, not
    /// awaited), so they work in parallel; the wait is just who finishes in time. One at a
    /// time here is fine for that: the sends already happened.
    static func drainAll() async {
        let budget = self.budget
        // Both fleets: what a window shows and what the broker runs headless (the manager
        // fleet and workers live in `SessionBroker.background`, unseen). Missing the
        // background fleet suspended only what was on screen and let workers' turns die as
        // crashes mid-update — the bug the field report caught.
        var conversations = Library.shared.open
        for b in SessionBroker.shared.liveBackground where !conversations.contains(where: { $0 === b }) {
            conversations.append(b)
        }
        let deadline = Int64((Date().addingTimeInterval(budget)).timeIntervalSince1970 * 1000)
        for c in conversations {
            c.sendDrain(deadline: deadline)
        }
        for c in conversations {
            let outcome = await c.awaitDrain(within: budget)
            if outcome == .timeout { c.forceKillEngine(reason: "app update (drain deadline missed)") }
        }
    }
}

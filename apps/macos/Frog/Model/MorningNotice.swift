import AppKit

/// The brief's one notification a day: when you're back at your Mac after 7 and it has
/// something you haven't seen. The engine decides (`frog --morning`, which also counts the
/// day); this asks at launch, on wake, and every half hour while frog is open.
@MainActor
enum MorningNotice {
    static let key = "morningNotice"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Launched by the watcher (`open -g -j Frog.app --args -FrogMorningNotice YES`) just to
    /// post the notice. AppKit reads `-Key value` arguments into UserDefaults' volatile argument
    /// domain, so this never sticks.
    static let headless = UserDefaults.standard.bool(forKey: "FrogMorningNotice")

    /// The notice was clicked before a window was up to show the brief (clicking it launched
    /// frog): the first window shows it.
    static var pendingShow = false

    /// Clicked: the brief, now or as soon as there's a window.
    static func show() {
        pendingShow = true
        NotificationCenter.default.post(name: .showBrief, object: nil)
    }

    private static var timer: Timer?

    static func start() {
        guard !SingleInstance.isTesting, timer == nil else { return }
        if headless {
            // Post it if it's due, give the post a moment, and go.
            Task {
                await check()
                try? await Task.sleep(for: .seconds(3))
                NSApp.terminate(nil)
            }
            return
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Give the network a moment after waking.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    await check()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in await check() }
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check()
        }
    }

    private static var checking = false

    static func check() async {
        guard enabled, !checking, await Notifier.shared.canPost() else { return }
        checking = true
        defer { checking = false }
        struct Notice: Decodable, Sendable { var title: String; var body: String }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let notice = try? await Frog.json(Notice?.self, args: ["--morning", "--json"], cwd: home) else { return }
        Notifier.shared.morning(title: notice.title, body: notice.body)
    }
}

extension Notification.Name {
    /// Show the brief: a new chat, where it sits under the frog.
    static let showBrief = Notification.Name("toys.frog.showBrief")
}

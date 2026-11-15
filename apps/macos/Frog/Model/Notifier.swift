import AppKit
import UserNotifications

/// frog's notifications on this Mac: what the model asked for with `Notify`, and the one
/// thing the app still raises on its own — a permission request you can answer right from the
/// banner (a card waiting is genuinely urgent).
///
/// A finished turn is not one of them. It's already on screen; the model calls `Notify` when
/// the person needs to know and isn't watching (see the engine's prompt and `tools/notify.rs`).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private var answers: [String: (Decision) -> Void] = [:]
    private var authorized: Bool?

    private enum Action {
        static let allow = "allow"
        static let deny = "deny"
        static let category = "permission"
    }

    /// The categories the phone's relay and this Mac agree on. Registering them is what makes
    /// a banner's buttons appear: an unregistered category shows the alert with no actions.
    enum Category {
        /// A permission request: Allow / Deny, answered without opening frog.
        static let permission = "PERMISSION"
        /// frog's own question (the `Ask` tool): tap to answer in the app.
        static let ask = "ASK"
        /// The model's `Notify` (its own urgency decides how loudly it arrives).
        static let notify = "NOTIFY"
        /// A finished turn. Kept for the phone, whose older relays still send it.
        static let done = "DONE"
    }

    func setup() {
        center.delegate = self
        center.setNotificationCategories(Self.categories())
    }

    /// The categories this app registers, as the system takes them. A function rather than an
    /// inline literal so a test can assert the set (the system's own read-back is empty in a
    /// test host, which has no signed bundle to hold a notification registration).
    static func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        // Both spellings of the permission category: this app's own posts use the lower case
        // identifier, the phone's relay sends "PERMISSION", and a category has to be registered
        // under the exact string a notification carries or its buttons vanish.
        return [
            UNNotificationCategory(identifier: Action.category, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.permission, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.ask, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.notify, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.done, actions: [], intentIdentifiers: []),
        ]
    }

    private var inBackground: Bool { !NSApp.isActive }

    /// Post only once you've said yes: the question is asked in context, the first time a
    /// task runs long (`PingLine`), never out of the blue from another app.
    private func post(_ content: UNMutableNotificationContent, id: String) {
        Task {
            guard await allowed() else { return }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func allowed() async -> Bool {
        if let authorized { return authorized }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorized = true
        case .denied: authorized = false
        default: return false  // Not asked yet; ask later, in context.
        }
        return authorized ?? false
    }

    /// Whether a notification would be shown (you've said yes).
    func canPost() async -> Bool { await allowed() }

    /// Whether notifications haven't been asked about yet.
    func notAskedYet() async -> Bool {
        guard !SingleInstance.isTesting else { return false }
        return await center.notificationSettings().authorizationStatus == .notDetermined
    }

    /// The system's question. True if you said yes.
    @discardableResult
    func ask() async -> Bool {
        let yes = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = yes
        return yes
    }

    // MARK: The model's Notify

    /// Whether the model's `Notify` may interrupt: you've said yes to notifications, and the
    /// one preference that still applies — "notify me when a turn finishes while I'm in
    /// another app" — is on. Off, a `Notify` is a transcript row and nothing else.
    private var notifyAllowed: Bool {
        !SingleInstance.isTesting
            && (UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true)
    }

    /// What the model asked for. `urgency` decides how loudly: `attention` is time-sensitive
    /// with a sound and bounces the Dock (when frog is behind another app); `done` is a quiet
    /// banner; `silent` is nothing at all — the tool call's row in the transcript is the whole
    /// notification.
    func note(title: String, body: String, urgency: NotifyUrgency, project: String?) {
        guard notifyAllowed else { return }
        if urgency == .attention { requestAttention() }
        guard urgency != .silent else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = project.map { "frog in \($0)" } ?? "frog"
        c.body = body
        c.categoryIdentifier = Category.notify
        c.threadIdentifier = project ?? "frog"
        switch urgency {
        case .attention:
            c.sound = .default
            // Needs them now: breaks through a Focus where the system allows it.
            c.interruptionLevel = .timeSensitive
        case .done:
            // A long job finished: a banner, not an interruption.
            c.interruptionLevel = .active
        case .silent:
            return
        }
        post(c, id: UUID().uuidString)
    }

    /// The Dock bounce, for `attention` only, and never while frog is frontmost (they're
    /// already looking at it). Injected so the rule is testable without an app to bounce.
    private(set) static var frontmost: @MainActor () -> Bool = { NSApp.isActive }

    /// Replace the frontmost check (tests, and the notification self-test).
    static func setFrontmostCheck(_ check: @escaping @MainActor () -> Bool) {
        frontmost = check
    }

    /// Whether an `attention` notification should bounce the Dock now: only when frog isn't
    /// the app in front. A finished turn gets a badge, never a bounce.
    static func wantsAttention(frontmost: Bool) -> Bool { !frontmost }

    /// Bounce once, informationally: the Dock icon hops until frog comes forward, which is
    /// the gentle form (a critical request keeps hopping and annoys).
    func requestAttention() {
        guard Self.wantsAttention(frontmost: Self.frontmost()),
              NSApp.activationPolicy() == .regular
        else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Permission requests

    func needsPermission(project: String, request: PermissionRequest, answer: @escaping (Decision) -> Void) {
        answers[request.id] = answer
        updateBadge()
        guard !SingleInstance.isTesting, inBackground else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(project) needs permission"
        c.body = "\(request.name): \(request.arg)"
        c.sound = .default
        c.categoryIdentifier = Action.category
        c.userInfo = ["permission": request.id]
        post(c, id: request.id)
    }

    /// The request was answered (anywhere): drop its notification and handler.
    func resolved(_ id: String) {
        answers[id] = nil
        center.removeDeliveredNotifications(withIdentifiers: [id])
        updateBadge()
    }

    // MARK: The badge

    /// Turns that finished while frog was in the background, since you last looked. Cleared
    /// when frog comes forward: it's a "while you were away" mark, not a count to clear.
    private var finishedAway = 0

    /// A turn ended while frog wasn't frontmost: a dot on the Dock icon, no banner, no bounce.
    /// (The model's own `Notify` is what raises an alert; this only says "there's something
    /// new in here" for someone who switched away mid-turn.)
    func turnFinishedAway() {
        guard !SingleInstance.isTesting, inBackground else { return }
        finishedAway += 1
        updateBadge()
    }

    /// frog came forward: everything the badge was counting has been looked at.
    func focus() {
        guard finishedAway > 0 || !answers.isEmpty else { return }
        finishedAway = 0
        updateBadge()
    }

    /// Pending permission requests win the badge (they're blocked work); otherwise the count
    /// of turns that finished while you were away.
    private func updateBadge() {
        let label: String? = if !answers.isEmpty {
            "\(answers.count)"
        } else if finishedAway > 0 {
            "●"
        } else {
            nil
        }
        NSApp.dockTile.badgeLabel = label
    }

    // MARK: Delivery self-test

    /// Fire one notification of every category, so delivery can be proven rather than assumed
    /// (`--test-notification`, or Debug › Test Notifications). `onResult` says what the system
    /// answered: authorized or not, which is the thing that silently fails in a dev build.
    func testDeliver(onResult: @escaping (String) -> Void) {
        Task {
            let settings = await center.notificationSettings()
            let status: String = switch settings.authorizationStatus {
            case .authorized: "authorized"
            case .provisional: "provisional"
            case .ephemeral: "ephemeral"
            case .denied: "denied"
            case .notDetermined: "not determined"
            @unknown default: "unknown"
            }
            let alertSetting: String = switch settings.alertSetting {
            case .enabled: "alerts on"
            case .disabled: "alerts off"
            @unknown default: "alerts unknown"
            }
            let categories = await center.notificationCategories()
            let names = categories.map(\.identifier).sorted().joined(separator: ",")
            let note = "notifications: \(status) · \(alertSetting) · categories [\(names)]"
            EngineProcess.log(note)
            onResult(note)
            guard await allowed() else {
                EngineProcess.log("notifications: nothing sent (not authorized)")
                return
            }
            let samples: [(String, String, String)] = [
                (Category.permission, "Test · permission", "Allow / Deny should be on this banner."),
                (Category.ask, "Test · question", "Tap should open frog."),
                (Category.notify, "Test · notify", "The model's Notify arrives like this."),
                (Category.done, "Test · done", "A finished turn (the phone's older path)."),
            ]
            for (category, title, body) in samples {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                c.sound = .default
                c.categoryIdentifier = category
                // Distinct ids, so each lands as its own banner in Notification Center.
                try? await center.add(UNNotificationRequest(identifier: "test-\(category)", content: c, trigger: nil))
            }
            NSApp.requestUserAttention(.informationalRequest)
            EngineProcess.log("notifications: sent \(samples.count) test notifications")
        }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.content.userInfo["permission"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if let id, let answer = answers[id] {
                switch action {
                case Action.allow: answer(.allow)
                case Action.deny: answer(.deny)
                default: NSApp.activate()
                }
            } else {
                NSApp.activate()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}

import AppKit
import UserNotifications

/// Notifications for when frog needs you and you're in another app: a finished turn, or a
/// permission request you can answer right from the notification.
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

    func setup() {
        center.delegate = self
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Action.category, actions: [allow, deny], intentIdentifiers: [])
        ])
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

    func turnFinished(project: String, text: String) {
        guard !SingleInstance.isTesting, inBackground, UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = project
        c.body = text
        c.sound = .default
        post(c, id: UUID().uuidString)
    }

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

    private func updateBadge() {
        NSApp.dockTile.badgeLabel = answers.isEmpty ? nil : "\(answers.count)"
    }

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

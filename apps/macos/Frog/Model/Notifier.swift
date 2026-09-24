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

    /// Ask for permission the first time we actually have something to say.
    private func post(_ content: UNMutableNotificationContent, id: String) {
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            }
            guard authorized == true else { return }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func turnFinished(project: String, text: String) {
        guard inBackground, UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = project
        c.body = text
        c.sound = .default
        post(c, id: UUID().uuidString)
    }

    func needsPermission(project: String, request: PermissionRequest, answer: @escaping (Decision) -> Void) {
        answers[request.id] = answer
        updateBadge()
        guard inBackground else { return }
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

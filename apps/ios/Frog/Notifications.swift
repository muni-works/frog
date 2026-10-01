import SwiftUI
import UserNotifications

/// frog's notifications: a question you can answer from the lock screen (Allow needs your face;
/// Deny doesn't), and a finished turn you can reply to without opening the app. Tapping either
/// opens the conversation. While you're reading a conversation, its own notifications stay quiet.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    private(set) var deviceToken: String?

    #if DEBUG
    static let apnsEnvironment = "sandbox"
    #else
    static let apnsEnvironment = "production"
    #endif

    enum Category {
        static let permission = "PERMISSION"
        static let done = "DONE"
    }

    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let reply = "REPLY"
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow",
                                         options: [.authenticationRequired], icon: .init(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny",
                                        options: [.destructive], icon: .init(systemImageName: "xmark"))
        let reply = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply",
                                                  options: [], icon: .init(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message frog")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.permission, actions: [allow, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.done, actions: [reply], intentIdentifiers: [], options: []),
        ])
    }

    /// Asked once, right after the first connection, when it's clear why.
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
        }
        #if !targetEnvironment(simulator)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func registered(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Delegate
    //
    // The completion-handler forms, finished on the main thread: UIKit asserts if the async
    // forms complete anywhere else.

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let session = notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            // The thread on screen already shows it.
            done(session != nil && session == Remote.shared.open?.sessionID ? [] : [.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? String
        let permission = info["permission"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { done() }
            guard let session else { return }
            var op: [String: Any]?
            switch action {
            case Action.allow, Action.deny:
                if let permission { op = ["op": "permission", "id": permission, "decision": action == Action.allow ? "allow" : "deny"] }
            case Action.reply:
                if let text, !text.isEmpty { op = ["op": "submit", "text": text] }
            case UNNotificationDefaultActionIdentifier:
                Remote.shared.requested = session
            default:
                break
            }
            guard let op else { return }
            // Answered from the lock screen: connect if we must, and hold on until it's sent.
            if await Remote.shared.perform(op: op, in: session) {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            Conversation.effects = PhoneEffects.shared
            // Models are named and placed the way the Mac does, from what the Mac says.
            ModelContext.providers = { Remote.shared.providers }
            DiagramLayout.mermaid = { code, _ in await Remote.shared.layoutMermaid(code) }
            Notifications.shared.setup()
            WatchLink.shared.start()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { Notifications.shared.registered(token) }
    }
}

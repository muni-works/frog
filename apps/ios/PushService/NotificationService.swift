import UserNotifications

/// Opens a sealed push from the Mac (`PushCrypto`) before iOS shows it: the real title, subtitle
/// and body replace the placeholder, and the details (the request, the session) land in
/// `userInfo` for the app, the content extension and the Allow / Deny buttons. Without the
/// pairing code, or with the wrong one, the placeholder stands.
final class NotificationService: UNNotificationServiceExtension {
    private var pending: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        pending = handler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        defer { handler(content) }
        guard let sealed = content.userInfo[PushCrypto.field] as? String,
              (content.userInfo["v"] as? Int ?? PushCrypto.version) == PushCrypto.version,
              let code = PairingCode.read(), !code.isEmpty,
              let data = PushCrypto.open(sealed, code: code),
              let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let alert = (inner["aps"] as? [String: Any])?["alert"] as? [String: Any] {
            if let t = alert["title"] as? String { content.title = t }
            if let s = alert["subtitle"] as? String { content.subtitle = s }
            if let b = alert["body"] as? String { content.body = b }
        }
        var info = content.userInfo
        info[PushCrypto.field] = nil
        info["v"] = nil
        for (k, v) in inner where k != "aps" { info[k] = v }
        content.userInfo = info
    }

    override func serviceExtensionTimeWillExpire() {
        if let content { pending?(content) }
        pending = nil
    }
}

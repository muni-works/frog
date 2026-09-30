import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// Long-press frog's question on the lock screen and see exactly what it wants to do, as the Mac
/// and the app show it (`QuestionBody`): the command, or the change as a diff.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<AnyView>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let info = content.userInfo
        var request: PermissionRequest?
        if let raw = info["request"], let data = try? JSONSerialization.data(withJSONObject: raw) {
            request = try? JSONDecoder.frog.decode(PermissionRequest.self, from: data)
        }
        let card = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FrogFace(mood: .waiting, size: 22).tint(Color.frog)
                Text(content.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let request {
                QuestionBody(request: request, maxLines: 24)
            } else {
                Text(content.body)
            }
        }
        .padding(16)

        host?.view.removeFromSuperview()
        let h = UIHostingController(rootView: AnyView(card))
        h.view.backgroundColor = .clear
        h.sizingOptions = .preferredContentSize
        addChild(h)
        view.addSubview(h.view)
        h.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            h.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h.view.topAnchor.constraint(equalTo: view.topAnchor),
            h.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        h.didMove(toParent: self)
        host = h
        let size = h.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: view.bounds.width, height: size.height)
    }
}

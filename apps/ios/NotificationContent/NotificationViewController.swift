import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// Long-press frog's question on the lock screen and see exactly what it wants to do: the
/// command, or the change as a diff, before you tap Allow.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<QuestionCard>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let info = content.userInfo
        var diff: FileDiff?
        if let preview = info["preview"], let data = try? JSONSerialization.data(withJSONObject: preview) {
            diff = try? JSONDecoder.frog.decode(FileDiff.self, from: data)
        }
        let card = QuestionCard(
            title: content.title,
            subtitle: content.subtitle,
            name: info["name"] as? String ?? "",
            arg: info["arg"] as? String ?? "",
            diff: diff)
        host?.view.removeFromSuperview()
        let h = UIHostingController(rootView: card)
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

struct QuestionCard: View {
    let title: String
    let subtitle: String
    let name: String
    let arg: String
    let diff: FileDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FrogFace(mood: .waiting, size: 30).tint(.frog)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let diff {
                DiffCard(diff: diff, limit: 24)
            } else if !arg.isEmpty {
                Text(name == "Bash" ? "$ " + arg : arg)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            }
        }
        .padding(16)
    }
}

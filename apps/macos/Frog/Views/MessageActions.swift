import AppKit
import SwiftUI

/// A small action under a message: a plain icon that brightens, with a soft plate, under the
/// pointer. No capsule of its own: the row sits in the text column like the text does.
struct MessageAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundStyle(hovering ? .primary : .tertiary)
                .background(.quaternary.opacity(hovering ? 0.6 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Under what you asked: when, then copy, rewind and fork. Fades in on hover, in a place of
/// its own so it covers nothing.
struct PromptActions: View {
    let turn: TurnState
    let visible: Bool
    let copy: () -> Void
    let rewind: () -> Void
    let fork: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let at = turn.startedAt {
                // Refreshes each minute, like "10 minutes ago" should.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.ago(at, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(at.formatted(date: .abbreviated, time: .shortened))
                        .padding(.trailing, 6)
                }
            }
            MessageAction(title: "Copy", symbol: "doc.on.doc", action: copy)
            if turn.number != nil, turn.finished {
                MessageAction(title: "Rewind to before this", symbol: "arrow.uturn.backward", action: rewind)
                MessageAction(title: "Fork from here", symbol: "arrow.triangle.branch", action: fork)
            }
        }
        .frame(height: 22)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.15), value: visible)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func ago(_ date: Date, now: Date = .now) -> String {
        now.timeIntervalSince(date) < 60 ? "Just now" : relative.localizedString(for: date, relativeTo: now)
    }
}

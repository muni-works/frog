#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A small action under a message: a plain icon that brightens, with a soft plate, under the
/// pointer. No capsule of its own: the row sits in the text column like the text does.
struct MessageAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    /// The label shows after a short pause, so passing over the row doesn't flash labels.
    @State private var labeled = false

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
        .task(id: hovering) {
            guard hovering else { labeled = false; return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { labeled = true }
        }
        // Actions sit at the column's right edge: the label grows leftward, not off the edge.
        .overlay(alignment: .topTrailing) {
            if labeled { ActionTooltip(text: title).offset(y: -30).transition(.opacity) }
        }
        .zIndex(labeled ? 1 : 0)
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: labeled)
    }
}

/// A quick label over a small control: dark, rounded, one line.
struct ActionTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}

/// Under what you asked: when, then copy, rewind and fork. Fades in on hover, in a place of
/// its own so it covers nothing.
struct PromptActions: View {
    let turn: TurnState
    let visible: Bool
    var canRewind = true
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
            MessageAction(title: "Copy message", symbol: "doc.on.doc", action: copy)
            if turn.number != nil, turn.finished {
                if canRewind {
                    MessageAction(title: "Rewind: undo from here", symbol: "arrow.uturn.backward", action: rewind)
                    MessageAction(title: "Fork a new conversation from here", symbol: "arrow.triangle.branch", action: fork)
                }
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

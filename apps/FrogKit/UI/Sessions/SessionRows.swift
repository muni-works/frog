import SwiftUI

/// A conversation in a list, the same on the Mac's sidebar and the phone's list: a monogram in
/// its project's color, the title, where it lives and when, and whether it's live.
struct Monogram: View {
    let session: SessionInfo
    let size: CGFloat
    let selected: Bool
    let live: SessionLive?

    var body: some View {
        let tint = session.isChat ? Color.secondary : FolderTint.color(session.folder)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(tint.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: selected ? 1.5 : 0.5)
            if session.isChat {
                Image(systemName: "bubble.left").font(.system(size: size * 0.38))
            } else {
                Text(initial).font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if live != nil {
                LiveGlyph(live: live)
                    .padding(2)
                    .background(.background, in: .circle)
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var initial: String {
        // "/no_think …" reads as N, not a slash.
        session.displayTitle.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }
}

/// Running, waiting on you, or finished unseen.
struct LiveGlyph: View {
    let live: SessionLive?

    var body: some View {
        switch live {
        case .running: ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        case .unread: Circle().fill(.tint).frame(width: 7, height: 7)
        case nil: EmptyView()
        }
    }
}

/// A project's color, the same on every launch (`hashValue` is seeded per process).
enum FolderTint {
    static func color(_ url: URL?) -> Color {
        guard let path = url?.standardizedFileURL.path else { return .secondary }
        var h: UInt64 = 5381
        for b in path.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

/// A conversation's title and, below it, where it lives and when; or, while it's live, what
/// it's doing or asking (`detail`).
struct ConversationRowLabel: View {
    let session: SessionInfo
    let live: SessionLive?
    /// The pane showing it, when the Mac's window is split.
    var pane: Int? = nil
    var showPlace = true
    /// Said instead of the place, e.g. frog's question or the step in hand.
    var detail: String? = nil
    var detailTint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let pane {
                    Text("\(pane)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(.tint, in: .rect(cornerRadius: 4))
                }
                if session.forkedFrom != nil {
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                }
                Text(session.displayTitle)
                    .lineLimit(1)
                    .fontWeight(live == .unread ? .semibold : .regular)
            }
            if let detail {
                Text(detail)
                    .font(.caption.weight(live == .waiting ? .medium : .regular))
                    .foregroundStyle(detailTint)
                    .lineLimit(1)
            } else if showPlace {
                HStack(spacing: 4) {
                    Image(systemName: session.isChat ? "bubble.left" : "folder")
                    Text(session.isChat ? "Chat" : session.folder?.lastPathComponent ?? "")
                        .lineLimit(1)
                    Text("·")
                    Text(SessionAge.short(session.modifiedDate))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Conversations filed under days, as the sidebar and the phone's list show them: Today,
/// Yesterday, Previous 7 Days, Previous 30 Days, Older. Empty groups are left out.
enum SessionDays {
    static func group<T>(_ items: [T], now: Date = Date(), day: (T) -> Date) -> [(String, [T])] {
        let cal = Calendar.current
        let week = cal.date(byAdding: .day, value: -7, to: now)!
        let month = cal.date(byAdding: .day, value: -30, to: now)!
        let older = items.filter { !cal.isDateInToday(day($0)) && !cal.isDateInYesterday(day($0)) }
        return [
            ("Today", items.filter { cal.isDateInToday(day($0)) }),
            ("Yesterday", items.filter { cal.isDateInYesterday(day($0)) }),
            ("Previous 7 Days", older.filter { day($0) >= week }),
            ("Previous 30 Days", older.filter { day($0) < week && day($0) >= month }),
            ("Older", older.filter { day($0) < month }),
        ].filter { !$0.1.isEmpty }
    }
}

enum SessionAge {
    /// "now", "5m", "3h", "2d", "4w", then a date.
    static func short(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        case ..<(86400 * 30): return "\(s / (86400 * 7))w"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

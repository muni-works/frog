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
                Image(systemName: "bubble.left").font(.frog(size: size * 0.38))
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
                .symbolEffect(.pulse, options: .repeat(3))
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

/// A row's status, on the right of its first line, as the web shows it: Running with a
/// breathing dot, Needs you, Failed, a pull request, or a green dot for a turn that finished
/// since you looked. Nothing when it's idle.
enum RowStatus: Equatable {
    case running, needsYou, failed, unread
    case pr(Int)

    static func derive(live: SessionLive?, end: SessionInfo.End?, pr: Int? = nil) -> RowStatus? {
        switch SessionEndGlyph.derive(live: live, end: end) {
        case .running: return .running
        case .waiting: return .needsYou
        case .failed: return .failed
        case .unread: return .unread
        case .idle: return pr.map(RowStatus.pr)
        }
    }
}

extension RowStatus {
    static func of(_ state: SessionNesting.State, pr: Int?) -> RowStatus? {
        switch state {
        case .running: .running
        case .waiting: .needsYou
        case .failed: .failed
        case .unread: .unread
        case .done: pr.map(RowStatus.pr)
        }
    }
}

struct RowStatusView: View {
    let status: RowStatus

    var body: some View {
        switch status {
        case .running:
            HStack(spacing: 5) {
                BreathingDot(live: true)
                Text("Running").foregroundStyle(Tokens.textSecondary)
            }
            .font(.frog(size: Tokens.Size.label))
        case .needsYou:
            // As on the web: an orange dot, then the words.
            HStack(spacing: 5) {
                Circle().fill(Tokens.signal).frame(width: 7, height: 7)
                Text("Needs you").font(.frog(size: Tokens.Size.label, weight: .medium)).foregroundStyle(Tokens.signal)
            }
        case .failed:
            Text("Failed").font(.frog(size: Tokens.Size.label, weight: .medium)).foregroundStyle(Tokens.fail)
        case .pr(let n):
            Text("#\(n)").font(.frog(size: Tokens.Size.label, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
        case .unread:
            Circle().fill(Tokens.accent).frame(width: 7, height: 7).help("Finished since you looked")
        }
    }
}

/// Frog green, breathing while something runs.
struct BreathingDot: View {
    let live: Bool
    var size: CGFloat = 6

    var body: some View {
        TimelineView(.animation(paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pulse = live ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4)) : 1
            Circle()
                .fill(Tokens.accent)
                .frame(width: size, height: size)
                .opacity(pulse)
        }
        .frame(width: size, height: size)
    }
}

/// A conversation as the web lists it: the title with its status on the right, and below it
/// what it's doing now or its last reply; idle with nothing to say, repo · turns · model. No
/// timestamps.
struct ConversationRowLabel: View {
    let session: SessionInfo
    let live: SessionLive?
    var end: SessionInfo.End? = nil
    /// The pane showing it, when the Mac's window is split.
    var pane: Int? = nil
    /// One line only (inside a project group the place is the group).
    var showPlace = true
    /// What it's doing now, its question, or its last reply.
    var detail: String? = nil
    var detailTint: Color = Tokens.textSecondary
    var pr: Int? = nil
    var turns: Int? = nil
    /// Hides the status (the Mac's hover menu takes its place).
    var hideStatus = false

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
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(Tokens.textSecondary)
                }
                Text(session.displayTitle)
                    .lineLimit(1)
                    .fontWeight(live == .unread ? .semibold : .regular)
                Spacer(minLength: 4)
                if let status = RowStatus.derive(live: live, end: end ?? session.end, pr: pr) {
                    RowStatusView(status: status).opacity(hideStatus ? 0 : 1)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.frog(size: Tokens.Size.meta, weight: live == .waiting ? .medium : .regular))
                    .foregroundStyle(detailTint)
                    .lineLimit(1)
            } else if showPlace {
                Text(idleLine)
                    .font(.frog(size: Tokens.Size.meta))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// repo · turns · model
    private var idleLine: String {
        var parts: [String] = []
        if session.isChat { parts.append("Chat") }
        else if let f = session.folder?.lastPathComponent, !f.isEmpty { parts.append(f) }
        if let turns, turns > 0 { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
        if !session.model.isEmpty { parts.append(ModelIdentity.rowName(session.model)) }
        return parts.joined(separator: " · ")
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

import SwiftUI

/// What will flush into the conversation at the next turn boundary: the background wakes the
/// engine parked, then the messages from other sessions queued behind the turn. Engine-side,
/// not the user's: a stop (esc) doesn't drop them, they go with the next turn.
struct PendingEvents: Equatable {
    struct Chip: Equatable, Identifiable {
        var id: String
        /// "monitor", "job", "timer", "task", "message", "note".
        var kind: String
        /// One line: "mon-1 timed out · wc -l out.jsonl", "okc manager: serving:true".
        var summary: String
        /// Everything, for the expanded chip.
        var payload: String
    }

    /// Chips shown before the overflow badge.
    static let shown = 3

    var chips: [Chip]

    init(queued: [String], messages: [SessionMessage], jobs: [String: BackgroundJob] = [:]) {
        let wakes = queued.flatMap { WakeEvent.parse($0) ?? [WakeEvent(kind: .note, id: "", attributes: [], body: $0)] }
        var chips = wakes.enumerated().map { i, w -> Chip in
            let what: String = switch w.kind {
            case .job: "job"
            case .monitor: "monitor"
            case .timer: "timer"
            case .task: "task"
            case .note: "note"
            }
            let label = jobs[w.id]?.label ?? (w.kind == .timer ? w.body : "")
            let head = [w.id, w.outcome].filter { !$0.isEmpty }.joined(separator: " ")
            let summary = [head, label].filter { !$0.isEmpty }.joined(separator: " · ")
            return Chip(id: "wake-\(i)", kind: what, summary: summary.isEmpty ? w.body : summary, payload: w.body)
        }
        chips += messages.enumerated().map { i, m -> Chip in
            let who = m.isSystem ? "system" : (m.name.isEmpty ? m.from : m.name)
            let line = m.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return Chip(id: "message-\(i)", kind: "message", summary: "message from \(who): \(line)", payload: m.body)
        }
        self.chips = chips
    }

    var isEmpty: Bool { chips.isEmpty }
    var visible: [Chip] { Array(chips.prefix(Self.shown)) }
    /// "+4 more" past the first three.
    var overflow: String? { chips.count > Self.shown ? "+\(chips.count - Self.shown) more" : nil }
    /// Background wakes are queued (not only session messages): "Dismiss all" applies.
    var hasWakes: Bool { chips.contains { $0.kind != "message" } }

    /// "2 pending results", plus where they go when nothing is running (after a stop).
    func caption(busy: Bool) -> String {
        let n = chips.count
        let head = "\(n) pending result\(n == 1 ? "" : "s")"
        return busy ? "\(head) · they arrive when this turn ends" : "\(head) · they go with your next message"
    }
}

/// The pending strip above the composer field: quiet chips (pending, not arrived), each
/// expanding to its full payload on click; a "+N more" badge past three. "Dismiss all" drops
/// the queued wakes and stops the pending timers and monitors in one click.
struct PendingEventsStrip: View {
    let pending: PendingEvents
    let busy: Bool
    var dismiss: (() -> Void)? = nil
    @State private var open: String?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(pending.caption(busy: busy))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let dismiss, pending.hasWakes {
                    Button("Dismiss all", action: dismiss)
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("Drop these wakes and stop the pending timers and monitors")
                }
            }
            ForEach(showAll ? pending.chips : pending.visible) { chip in
                VStack(alignment: .leading, spacing: 2) {
                    Button { open = open == chip.id ? nil : chip.id } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "hourglass").imageScale(.small)
                            Text(chip.kind).fontWeight(.medium)
                            Text(chip.summary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(chip.payload)
                    if open == chip.id {
                        Text(chip.payload)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 16)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let more = pending.overflow, !showAll {
                Button(more) { showAll = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
        }
        .opacity(0.75)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: pending)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pending.caption(busy: busy))
    }
}

import SwiftUI

/// One agent (a `Task` call) as a one-line row under its session in the sidebar: glyph, name,
/// the step it's on right now, and how far along. The line, with the session's own row above,
/// is the single home for agent status (docs/design/agents/calm.html).
struct AgentRow: View {
    let agent: AgentRowInfo
    var depth: Int = 0
    var highlight = ""

    @ViewBuilder
    private var glyph: some View {
        switch agent.state {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                .help("working")
        case .waiting:
            Image(systemName: "hand.raised.fill").font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("needs your approval")
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.red)
                .help("failed")
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green.opacity(0.75))
                .help("reported back")
        }
    }

    /// After the name: what it's doing, "needs approval", or the failure's first line.
    private var detail: (text: String, color: Color?)? {
        switch agent.state {
        case .running: agent.activity.map { ($0, nil) }
        case .waiting: ("needs approval", .orange)
        case .failed: (agent.activity ?? "failed", .red)
        case .done: nil
        }
    }

    /// Words for the row's right edge: the plan's "3/5", else steps and time ("4 steps · 42s").
    static func progress(_ agent: AgentRowInfo, now: Date) -> String? {
        guard !agent.finished else { return nil }
        if let plan = plan(agent) { return "\(plan.done)/\(plan.total)" }
        var parts: [String] = []
        if agent.steps > 0 { parts.append("\(agent.steps) step\(agent.steps == 1 ? "" : "s")") }
        if let since = agent.startedAt {
            let secs = now.timeIntervalSince(since)
            // Over an hour usually means a stale clock (a replayed start), not a real run.
            if secs >= 1, secs < 3600 { parts.append(ActivityWords.duration(secs)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func plan(_ agent: AgentRowInfo) -> (done: Int, total: Int)? {
        guard let d = agent.planDone, let t = agent.planTotal, t > 0, d <= t else { return nil }
        return (d, t)
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: AttentionMetrics.leading(depth))
            glyph
                .frame(width: AttentionMetrics.disclosure)
            HStack(spacing: 5) {
                Text(agent.title)
                    .font(.system(size: 12))
                    .foregroundStyle(agent.finished ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail {
                    Text("· " + detail.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(detail.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !agent.finished {
                // The shared seconds clock, not a timeline per row (re-checked every frame).
                if let words = Self.progress(agent, now: SecondsClock.shared.now) {
                    Text(words)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
        .padding(.trailing, 6)
        .frame(height: AttentionMetrics.rowHeight)
        .overlay(alignment: .bottomLeading) {
            // The hairline: the agent's own plan, under the row from its name to the edge.
            if let plan = Self.plan(agent), !agent.finished {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary)
                            .frame(width: geo.size.width * CGFloat(plan.done) / CGFloat(plan.total))
                    }
                }
                .frame(height: 1.5)
                .padding(.leading, AttentionMetrics.leading(depth) + AttentionMetrics.disclosure + 5)
                .padding(.trailing, 6)
                .padding(.bottom, 2)
                .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .help(help)
    }

    private var help: String {
        switch agent.state {
        case .running: "\(agent.title): \(agent.activity ?? "working")"
        case .waiting: "\(agent.title) needs your approval"
        case .failed: "\(agent.title) failed: \(agent.activity ?? "")"
        case .done: "\(agent.title) reported back"
        }
    }
}

/// An open conversation's agents (its Task calls) as one-line rows under its sidebar row:
/// working, waiting on you, or finished during the turn that's running. Once that turn ends,
/// the finished ones fold into "› N done · M failed". A row opens the session (agents aren't
/// sessions of their own yet: live-only, see NOTES.md).
struct SessionAgents: View {
    let conversation: Conversation
    let depth: Int
    let open: () -> Void

    var body: some View {
        // Read on every streamed flush (`agentList` walks the turn), but the rows below only
        // redraw when the list itself changes: they re-ran ~160 times a second while working.
        AgentListRows(list: conversation.agentList, depth: min(depth, SessionNesting.maxDepth), open: open)
            .equatable()
    }
}

private struct AgentListRows: View, Equatable {
    let list: AgentList
    let depth: Int
    let open: () -> Void
    @State private var foldOpen = false

    nonisolated static func == (a: Self, b: Self) -> Bool { a.list == b.list && a.depth == b.depth }

    var body: some View {
        ForEach(list.rows) { agent in
            AgentRow(agent: agent, depth: depth).onTapGesture(perform: open)
        }
        if !list.folded.isEmpty {
            AgentFoldRow(list: list, depth: depth, open: foldOpen) {
                withAnimation(.snappy(duration: 0.2)) { foldOpen.toggle() }
            }
            if foldOpen {
                ForEach(list.folded) { agent in
                    AgentRow(agent: agent, depth: depth).onTapGesture(perform: open)
                }
            }
        }
    }
}

/// A session's finished agents folded into one line once the turn that ran them ended:
/// "› 2 done · 1 failed". It opens to their rows.
struct AgentFoldRow: View {
    let list: AgentList
    let depth: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Color.clear.frame(width: AttentionMetrics.leading(depth))
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: AttentionMetrics.disclosure)
                if list.done > 0 { Text("\(list.done) done") }
                if list.failed > 0 {
                    Text("\(list.done > 0 ? " · " : "")\(list.failed) failed").foregroundStyle(.red.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(open ? "Hide finished agents" : "Show \(list.folded.count) finished agent\(list.folded.count == 1 ? "" : "s")")
    }
}

/// One clock for the sidebar's running-agent timers ("4 steps · 42s"): only rows that read it
/// redraw, once a second.
@MainActor
@Observable
final class SecondsClock {
    static let shared = SecondsClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SecondsClock.shared.now = Date() }
        }
    }
}

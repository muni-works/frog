import SwiftUI

/// One agent (a `Task` call) as a one-line row under its session in the sidebar: glyph, name,
/// the step it's on right now, and how far along. The line, with the session's own row above,
/// is the single home for agent status (docs/design/agents/calm.html).
struct AgentRow: View {
    let agent: AgentRowInfo
    var depth: Int = 0
    var highlight = ""

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

    /// "· Reading main.rs" while it runs, or the failure's first line, secondary color.
    private var activityLine: String? {
        switch agent.state {
        case .running, .failed: agent.activity
        case .waiting: nil
        case .done: nil
        }
    }

    /// The failure's head, shortened for one line.
    private var failureHead: String? {
        guard case .failed = agent.state, let a = agent.activity else { return nil }
        return a.split(separator: "\n").first.map { String($0).prefix(60) }.map(String.init)
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: AttentionMetrics.leading(depth))
            glyph
                .frame(width: AttentionMetrics.disclosure)
            HStack(spacing: 5) {
                Text(agent.title)
                    .font(.system(size: 12))
                    .foregroundStyle(agent.state == .running ? Color.primary : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let activity = agent.state == .failed ? failureHead : activityLine {
                    Text("· " + activity)
                        .font(.system(size: 11))
                        .foregroundStyle(agent.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if agent.state == .waiting {
                    Text("· needs approval")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            if case .running = agent.state {
                if let (done, total) = planProgress {
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    // The hairline: the agent's own plan, as a 2 pt line under the row.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(.secondary.opacity(0.7))
                                .frame(width: total > 0 ? geo.size.width * CGFloat(done) / CGFloat(total) : 0)
                        }
                    }
                    .frame(width: 34, height: 2)
                } else if let startedAt = agent.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ActivityWords.duration(ctx.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(height: AttentionMetrics.rowHeight - 2)
        .contentShape(.rect)
    }

    private var planProgress: (done: Int, total: Int)? {
        guard let d = agent.planDone, let t = agent.planTotal, t > 0, d <= t else { return nil }
        return (d, t)
    }
}

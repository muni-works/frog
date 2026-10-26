import SwiftUI

/// A `Task` call: the subagent working live (what it's doing, its recent steps, its report as
/// it's written), then its report. Stop ends just the subagent; Open shows its whole run.
struct SubagentCard: View {
    let arg: String
    let item: ItemState
    let conversation: Conversation
    @State private var showSteps = false
    @State private var showRun = false
    @State private var expanded = false

    private var run: SubagentRun? { item.subagent }
    private var running: Bool { !item.done }
    private var failed: Bool { item.result.map { $0.outcome != .ok } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if running {
                live
            } else if let r = item.result {
                report(r)
            }
        }
        .padding(TurnSpace.Card.padding)
        .background(.quaternary.opacity(running ? 0.45 : 0.3), in: .rect(cornerRadius: TurnSpace.Card.radius))
        .overlay {
            if running {
                RoundedRectangle(cornerRadius: TurnSpace.Card.radius)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
        }
        .animation(.snappy(duration: 0.25), value: run?.items.count)
        .animation(.snappy(duration: 0.25), value: item.done)
        .sheet(isPresented: $showRun) {
            SubagentRunSheet(title: arg, run: run, conversation: conversation)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(running ? AnyShapeStyle(.tint) : AnyShapeStyle(failed ? .red : .secondary))
                .symbolEffect(.pulse, isActive: running)
                .frame(width: TurnSpace.Inset.icon)
            Text("Subagent").fontWeight(.semibold).font(.callout)
            Text(arg.isEmpty ? "Task" : arg)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(stats)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if running {
                Button {
                    conversation.stopSubagent(item.id)
                } label: {
                    Label(run?.stopping == true ? "Stopping" : "Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(run?.stopping == true)
                .help("Stop the subagent; the turn continues with what it found so far")
            }
            if run != nil {
                Button {
                    showRun = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open the subagent's full run")
            }
        }
    }

    private var stats: String {
        var parts: [String] = []
        if let run {
            if running { parts.append(run.activity) }
            let n = run.steps
            if n > 0 { parts.append("\(n) step\(n == 1 ? "" : "s")") }
            let secs = Int((run.endedAt ?? Date()).timeIntervalSince(run.startedAt))
            parts.append(secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s")
            if running, let tps = run.tokensPerSec, tps > 0 { parts.append(ModelStats.speedText(tps * ModelStats.wordsPerToken)) }
        } else if running {
            parts.append("Starting")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Live

    @ViewBuilder
    private var live: some View {
        let items = run?.items ?? []
        let steps = items.filter { if case .tool = $0.kind { true } else { false } }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps.suffix(3)) { step in
                StepRow(item: step)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let last = items.last, !last.done {
                switch last.kind {
                case .reasoning:
                    Text(tail(last.text, lines: 2))
                        .font(.callout.italic())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .transition(.opacity)
                case .message where !last.text.isEmpty:
                    MarkdownView(text: last.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.leading, TurnSpace.Inset.iconColumn)
    }

    // MARK: Done

    @ViewBuilder
    private func report(_ r: Item.ToolResult) -> some View {
        let text = r.output
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: expanded ? nil : 220, alignment: .top)
                .clipped()
                .mask {
                    if expanded || text.count < 900 {
                        Color.black
                    } else {
                        LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                }
            HStack(spacing: 12) {
                if text.count >= 900 {
                    Button(expanded ? "Show less" : "Show more") { withAnimation(.snappy) { expanded.toggle() } }
                        .linkButton()
                }
                if let run, run.steps > 0 {
                    Button(showSteps ? "Hide steps" : "Show \(run.steps) step\(run.steps == 1 ? "" : "s")") {
                        withAnimation(.snappy) { showSteps.toggle() }
                    }
                    .linkButton()
                }
            }
            .font(.caption)
            if showSteps, let run {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(run.items.filter { if case .tool = $0.kind { true } else { false } }) { StepRow(item: $0) }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, TurnSpace.Inset.iconColumn)
    }

    private func tail(_ s: String, lines: Int) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: " ")
    }
}

/// One tool call inside a subagent: icon, name, argument, and whether it's done.
private struct StepRow: View {
    let item: ItemState

    var body: some View {
        if case .tool(let name, let arg) = item.kind {
            HStack(spacing: 7) {
                Image(systemName: ToolIcon.symbol(name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(ToolIcon.title(name)).font(.caption.weight(.medium))
                Text(arg)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !item.done {
                    ProgressView().controlSize(.mini)
                } else if item.result?.outcome == .ok {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                }
            }
        }
    }
}

/// Everything the subagent did, as a transcript.
private struct SubagentRunSheet: View {
    let title: String
    let run: SubagentRun?
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title.isEmpty ? "Subagent" : title, systemImage: "person.2.fill").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(run?.items ?? []) { item in
                        ItemView(item: item, conversation: conversation)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }
}

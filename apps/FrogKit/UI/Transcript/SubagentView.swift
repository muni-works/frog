import SwiftUI

/// A `Task` call as a quiet step row: the agent's name, what it's doing right now (or how it
/// went), and Stop while it runs. Clicking it opens the agent's whole run (the same views the
/// main transcript uses). This replaces the big subagent card (see NOTES.md, the calm-agent
/// direction) — removed only once this row renders everywhere the card did.
struct AgentStepRow: View {
    let arg: String
    let item: ItemState
    let conversation: Conversation
    @State private var showRun = false

    private var run: SubagentRun? { item.subagent }
    private var running: Bool { !item.done }
    private var failed: Bool { item.result.map { $0.outcome != .ok } ?? false }

    /// The agent's own TodoWrite plan: done and total, when it wrote one.
    private var planProgress: (done: Int, total: Int)? {
        guard let todos = run?.items.last(where: { step in
            if case .tool("TodoWrite", _) = step.kind { return step.done }
            return false
        })?.result?.input?["todos"]?.array,
           !todos.isEmpty else { return nil }
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        return (done, todos.count)
    }

    var body: some View {
        HStack(spacing: TurnSpace.Inset.snug) {
            Image(systemName: "person.2.fill")
                .font(.caption)
                .foregroundStyle(running ? AnyShapeStyle(.tint) : AnyShapeStyle(failed ? .red : .secondary))
                .symbolEffect(.pulse, isActive: running)
                .frame(width: TurnSpace.Inset.icon)
            Text(arg.isEmpty ? "Agent" : arg)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            if running, let activity = run?.activity {
                Text("· \(activity)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if failed, let head = item.result?.output.split(separator: "\n").first {
                Text("· failed: \(String(head.prefix(60)))")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let r = item.result, r.outcome == .ok {
                Text("· reported")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let (done, total) = planProgress {
                Text("\(done)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if running {
                if let since = item.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ActivityWords.duration(ctx.date.timeIntervalSince(since)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                Button {
                    conversation.stopSubagent(item.id)
                } label: {
                    Image(systemName: run?.stopping == true ? "hourglass" : "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(run?.stopping == true)
                .help(run?.stopping == true ? "Stopping…" : "Stop the agent; the turn continues with what it found so far")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showRun ? 90 : 0))
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard !running else { return }
            showRun = true
        }
        .sheet(isPresented: $showRun) {
            SubagentRunSheet(title: arg, run: run, conversation: conversation)
        }
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

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

    var body: some View {
        HStack(spacing: TurnSpace.Inset.snug) {
            // A step like any other: "Agent: audit the sidebar · Reading main.rs · 3/5".
            Text(ActivityWords.row(item))
                .lineLimit(1)
                .truncationMode(.tail)
            if running, let activity = run?.activity {
                Text("· \(activity)")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if failed {
                Text("· failed")
                    .foregroundStyle(.red)
                    .help(item.result.flatMap { agentFailureHead($0.output) } ?? "")
            }
            if running, let plan = run?.plan {
                Text("· \(plan.done)/\(plan.total)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if running {
                // No per-agent clock: the turn's live status row is the app's one clock.
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
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(.rect)
        // Running or done, its run opens: watching an agent work is the point of the sheet
        // (built from this row's item, so it follows the run live).
        .onTapGesture { showRun = true }
        .sheet(isPresented: $showRun) {
            SubagentRunSheet(title: arg, run: run, conversation: conversation)
        }
    }
}

/// A finished agent's step, opened: its report (or the failure), capped, and a way to its
/// whole run. The parent's answer usually quotes what matters; this is for checking.
struct AgentReport: View {
    let arg: String
    let item: ItemState
    let conversation: Conversation
    @State private var showRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
            if let r = item.result, !r.output.isEmpty {
                Text(r.output)
                    .font(.callout)
                    .foregroundStyle(r.outcome == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let claims = item.subagent?.claims {
                // The worker's claims (review-ux step 2, read-only): what it says about the
                // world and the commands that check each — under the report it came with.
                OutcomeCard(claims: claims)
                    .equatable()
            }
            if let run = item.subagent, run.steps > 0 {
                Button("Show its \(run.steps) step\(run.steps == 1 ? "" : "s")") { showRun = true }
                    .linkButton()
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showRun) {
            SubagentRunSheet(title: arg, run: item.subagent, conversation: conversation)
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

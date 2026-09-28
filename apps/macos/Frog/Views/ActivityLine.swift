import SwiftUI

/// What frog did between two pieces of text, as a line of prose in the text column: muted,
/// no card. Clicking it opens a light list of the steps; each step opens to its output.
struct ActivityLine: View {
    let group: ActivityGroup
    let conversation: Conversation
    /// The turn is running: a long thought streams below the line, and a subagent shows live.
    var live = false
    /// Opened. Not private so snapshots can render it open.
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Running steps aren't in the sentence yet; the live line says what's happening.
            if !group.done.isEmpty {
                line
            }
            if expanded {
                ActivitySteps(steps: group.steps, conversation: conversation)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if live, let now = group.current {
                liveStep(now)
            }
            if let p = conversation.permission, group.steps.contains(where: { $0.needsPermission && $0.id == p.item }) {
                PermissionCard(request: p, conversation: conversation)
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private var line: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            Text("\(ActivityText(pieces: group.summary).text)  \(chevron)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(expanded ? "Hide steps" : "Show steps")
    }

    private var chevron: Text {
        Text(Image(systemName: expanded ? "chevron.down" : "chevron.right"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func liveStep(_ item: ItemState) -> some View {
        switch item.kind {
        case .reasoning where !ActivityGroup.isShort(item):
            LiveThought(text: item.text)
        case .tool("Task", let arg):
            // A subagent works for a while; show it working, with its Stop button.
            SubagentCard(arg: arg, item: item, conversation: conversation)
        default:
            EmptyView()
        }
    }
}

/// The summary pieces as one `Text`: muted words, diff counts green and red, failures orange.
struct ActivityText {
    let pieces: [ActivityWords.Piece]

    var text: Text {
        pieces.reduce(Text(verbatim: "")) { acc, p in
            switch p {
            case .text(let s):
                Text("\(acc)\(Text(verbatim: s))")
            case .diff(let a, let r):
                Text("\(acc)\(Text(verbatim: "+\(a)").foregroundStyle(.green)) \(Text(verbatim: "−\(r)").foregroundStyle(.red))")
            case .failed(let n):
                Text("\(acc)\(Text(verbatim: "\(n) failed").foregroundStyle(.orange))")
            }
        }
        .monospacedDigit()
    }
}

/// A long thought as it streams: its latest lines, muted, until it folds into its line.
struct LiveThought: View {
    let text: String

    var body: some View {
        Text(tail)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(6, reservesSpace: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    private var tail: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(6).joined(separator: "\n")
    }
}

/// The opened line: one row per step, in a hairline outline.
struct ActivitySteps: View {
    let steps: [ItemState]
    let conversation: Conversation

    var body: some View {
        Group {
            if steps.count == 1, let thought = steps.first, thought.kind == .reasoning {
                // A lone thought's line already says "Thought for 12s"; open, it's the thought.
                Text(thought.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        if i > 0 { Divider().opacity(0.4) }
                        ActivityStepRow(item: step, conversation: conversation)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// One step: "Read PaneView.swift", "Ran xcodebuild test · passed". Opens to the output.
struct ActivityStepRow: View {
    let item: ItemState
    let conversation: Conversation
    /// Opened. Not private so snapshots can render it open.
    @State var expanded = false

    private var name: String {
        if case .tool(let name, _) = item.kind { name } else { "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(ActivityWords.row(item))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcome
                    Spacer(minLength: 8)
                    status
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                detail.transition(.opacity)
            } else if !item.done, item.kind != .reasoning {
                ToolDetail(name: name, item: item, expanded: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var detail: some View {
        switch item.kind {
        case .reasoning:
            Text(item.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool("Task", let arg):
            SubagentCard(arg: arg, item: item, conversation: conversation)
        case .tool(let name, _):
            VStack(alignment: .leading, spacing: 8) {
                if let images = item.result?.images, !images.isEmpty {
                    ToolImages(images: images)
                }
                ToolDetail(name: name, item: item)
                if let why = item.autoReason {
                    Label("Auto: \(why)", systemImage: "wand.and.sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help("Auto mode's classifier let this run without asking")
                }
            }
        default:
            EmptyView()
        }
    }

    /// How it went, after the name: "· passed", "+3 −1", "Read 8 lines".
    @ViewBuilder
    private var outcome: some View {
        if let r = item.result {
            let tests = (name == "Bash" || name == "!") && ActivityWords.isTest(item.arg)
            switch r.outcome {
            case .denied: Text("· denied").foregroundStyle(.orange)
            case .skipped: Text("· skipped").foregroundStyle(.tertiary)
            case .error:
                Text(r.display?.hasPrefix("refused") == true ? "· repeated call refused" : "· failed").foregroundStyle(.red)
            case .ok:
                if let d = r.diff {
                    ActivityText(pieces: [.diff(added: d.added, removed: d.removed)]).text
                } else if tests {
                    Text("· passed").foregroundStyle(.tertiary)
                } else if let display = r.display, !display.isEmpty, !display.contains("\n"), display.count < 60,
                          // "Read 8 lines" after "Read Sidebar.swift" says it twice.
                          display.split(separator: " ").first != ActivityWords.row(item).split(separator: " ").first {
                    Text("· \(display)").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if item.needsPermission {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        } else if !item.done {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The running turn's last line: a small spinner and what's happening now.
struct LiveStatus: View {
    let text: String
    /// When the current step started, for "Running the tests… 12s".
    let since: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(text + elapsed(at: ctx.date))
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
        }
        .foregroundStyle(.secondary)
        .animation(.default, value: text)
    }

    private func elapsed(at now: Date) -> String {
        guard let since else { return "" }
        let secs = now.timeIntervalSince(since)
        // Under a second isn't worth saying; over an hour usually means a replayed session.
        guard secs >= 1, secs < 3600 else { return "" }
        return " " + ActivityWords.duration(secs)
    }
}

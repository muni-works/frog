import SwiftUI

/// What frog did between two pieces of text, as a line of prose in the text column: muted,
/// no card. Clicking it opens a light list of the steps; each step opens to its output.
struct ActivityLine: View {
    @Environment(\.pinsQuestions) private var pinsQuestions
    let group: ActivityGroup
    let conversation: Conversation
    /// The turn is running: a long thought streams below the line, and a subagent shows live.
    var live = false
    var verbosity: Verbosity = .normal
    /// Opened. Not private so snapshots can render it open.
    @State var expanded: Bool

    init(group: ActivityGroup, conversation: Conversation, live: Bool = false, verbosity: Verbosity = .normal, expanded: Bool? = nil) {
        self.group = group
        self.conversation = conversation
        self.live = live
        self.verbosity = verbosity
        // Verbose shows every step; otherwise a line opens on click.
        _expanded = State(initialValue: expanded ?? (verbosity == .verbose))
    }

    /// A long thought on a line of its own ("Thought for 12s"): it gets a gist.
    private var thought: ItemState? {
        guard group.steps.count == 1, let t = group.steps.first, t.kind == .reasoning, t.done,
              !ActivityGroup.isShort(t) else { return nil }
        return t
    }

    private var gist: String? {
        thought.flatMap { Gists.shared.gist(session: conversation.sessionID, item: $0.id) }
    }

    var body: some View {
        #if DEBUG
        let _ = TranscriptProbe.row()
        #endif
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
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
            if !pinsQuestions, let p = conversation.permission, group.steps.contains(where: { $0.needsPermission && $0.id == p.item }) {
                PermissionCard(request: p, conversation: conversation)
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
        // Asked for once the line shows (the lazy transcript only builds what's near the view).
        .task(id: thought?.id) {
            guard let t = thought else { return }
            Gists.shared.request(session: conversation.sessionID, item: t.id, thought: t.text)
        }
        .onChange(of: verbosity) { _, v in expanded = v == .verbose }
    }

    private var line: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            // A UI size under the 14pt answer, secondary: it reads as a margin note, not text.
            Text("\(ActivityText(pieces: group.summary).text)\(gistText)  \(chevron)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .help(expanded ? "Hide steps" : "Show steps")
    }

    /// " · Decided to…", quieter than the line it follows.
    private var gistText: Text {
        guard let gist else { return Text(verbatim: "") }
        return Text(verbatim: " · \(gist)").foregroundStyle(.tertiary)
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
            // Normal previews it beside "Thinking…" (see `LiveStatus`); verbose shows it here.
            if verbosity == .verbose {
                LiveThought(text: item.text)
            }
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

/// A thought as it streams, in one line beside "Thinking…": the sentence being written, replaced
/// by the next. Enough to see what it's working on, without a block of text growing and
/// shrinking.
struct ThoughtSubtitle: View {
    let text: String

    var body: some View {
        let (index, sentence) = Self.current(text)
        Text(sentence)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            // The newest words stay in view as the sentence outgrows the line.
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(index)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: index)
    }

    /// The sentence being written and its position, so a new sentence fades in. One that's
    /// barely begun shows the one before it until it has a few words.
    static func current(_ text: String) -> (Int, String) {
        var sentences: [String] = []
        var sentence = ""
        for ch in text {
            if ch == "\n" {
                if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(sentence) }
                sentence = ""
                continue
            }
            sentence.append(ch)
            if ".?!".contains(ch) {
                sentences.append(sentence)
                sentence = ""
            }
        }
        let tail = sentence.trimmingCharacters(in: .whitespaces)
        if tail.count >= 24 || sentences.isEmpty {
            return (sentences.count, tail)
        }
        return (sentences.count - 1, sentences[sentences.count - 1].trimmingCharacters(in: .whitespaces))
    }
}

/// The opened line: one row per step, in a hairline outline.
struct ActivitySteps: View {
    let steps: [ItemState]
    let conversation: Conversation

    var body: some View {
        Group {
            if steps.count == 1, let thought = steps.first, thought.kind == .reasoning {
                // A lone thought's line already says "Thought for 12s"; open, it's the thought,
                // set off like a quote rather than boxed.
                Text(thought.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TurnSpace.Inset.roomy)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.separator).frame(width: 2)
                    }
                    .padding(.vertical, TurnSpace.Inset.hair)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        if i > 0 { Divider().opacity(0.4) }
                        ActivityStepRow(item: step, conversation: conversation)
                    }
                }
                .padding(.vertical, TurnSpace.Inset.hair)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
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
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: TurnSpace.Inset.snug) {
                    Text(rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcome
                    runningClock
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
                ToolDetail(name: name, item: item, expanded: false, root: conversation.folder.path)
            }
        }
        .padding(.horizontal, TurnSpace.Inset.card)
        .padding(.vertical, TurnSpace.Inset.snug)
    }

    /// The row's words. A shell row running now says the intent ("Running git log…" from the
    /// elided command) rather than the raw text; done, it reads as always ("Ran …"), with a
    /// gist replacing the raw command when one arrived.
    private var rowTitle: String {
        guard name == "Bash" || name == "!" else { return ActivityWords.row(item) }
        if !item.done {
            let elided = CommandElision.elide(item.arg, from: conversation.folder.path)
            return ActivityWords.isTest(item.arg) ? "Running the tests…" : "Running \(elided)…"
        }
        if let gist = CommandGists.shared.gist(for: item.arg) {
            return gist
        }
        return "Ran \(CommandElision.elide(item.arg, from: conversation.folder.path))"
    }

    /// A running shell row's honest elapsed timer ("1m 40s"), counting while it runs, and a
    /// subtle hint that output is streaming (its newest line), so a silent-looking wait
    /// reads as live.
    @ViewBuilder
    private var runningClock: some View {
        if !item.done, let since = item.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: TurnSpace.Inset.snug) {
                    if !item.output.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Output is streaming")
                    }
                    Text(ActivityWords.duration(ctx.date.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
                .contentTransition(.opacity)
            }
        }
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
            VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
                if !item.displayImages.isEmpty {
                    ToolImages(images: item.displayImages, preview: !item.done)
                    if !item.done { Text("Approximate step preview").font(.caption).foregroundStyle(.secondary) }
                }
                ToolDetail(name: name, item: item, root: conversation.folder.path)
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
    /// A thought as it streams: its current sentence, after "Thinking… 4s".
    var preview: String?

    var body: some View {
        HStack(spacing: TurnSpace.Inset.row) {
            ProgressView().controlSize(.mini)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(text + elapsed(at: ctx.date))
                    .font(.callout)
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
            .fixedSize()
            if let preview, !ThoughtSubtitle.current(preview).1.isEmpty {
                ThoughtSubtitle(text: preview)
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

/// The first Tang request loads the selected model's weights. Tang does not expose a byte count
/// for that operation, so this is deliberately an indeterminate sweep rather than a made-up
/// percentage.
struct ModelLoadingStatus: View {
    let model: String
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(since))
            VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
                HStack(spacing: TurnSpace.Inset.row) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tint)
                    Text("Loading \(model) into memory")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Text(Self.elapsed(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ModelLoadBar(elapsed: elapsed)
                Text("Starting the first response")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading \(model) into memory")
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let wholeSeconds = Int(seconds.rounded(.down))
        return wholeSeconds < 60 ? "\(wholeSeconds)s" : "\(wholeSeconds / 60)m \(wholeSeconds % 60)s"
    }
}

private struct ModelLoadBar: View {
    let elapsed: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let beamWidth = min(width * 0.34, max(40, width * 0.16))
            let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.35) / 1.35)
            let offset = max(0, width - beamWidth) * phase

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.2), .accentColor, .accentColor.opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: beamWidth)
                    .offset(x: offset)
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

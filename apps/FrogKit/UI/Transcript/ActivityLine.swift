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

    private var failedCommands: [ItemState] {
        group.done.filter { ["Bash", "!"].contains(Self.toolName($0)) && $0.result?.outcome == .error
            && !($0.result.map { $0.display ?? $0.output } ?? "").isEmpty }
    }

    private static func toolName(_ item: ItemState) -> String {
        if case .tool(let name, _) = item.kind { name } else { "" }
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

    /// One line per step, as the web shows them: icon, verb, the argument in mono ("Read
    /// `crates/x.rs`", "Ran `cargo test`", "Edited `f` +6 −3"). A thought is one quiet line.
    /// The first line carries the › that opens the steps' output.
    private var line: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
                ForEach(Array(VerbLine.lines(group.done).enumerated()), id: \.offset) { i, v in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        VerbLineView(line: v)
                        if i == 0 {
                            Text(verbatim: "  ")
                            chevron
                            gistText.font(.callout).lineLimit(1)
                        }
                    }
                    // A failed command's output, under its own line, as on the web.
                    if !expanded, let step = failedCommands.first(where: { $0.id == v.itemID }) {
                        ToolDetail(name: Self.toolName(step), item: step, expanded: true, root: conversation.folder.path)
                            .padding(.leading, 22)
                            .padding(.vertical, 2)
                    }
                }
            }
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
            // An agent works for a while; show its step row, with its Stop button.
            AgentStepRow(arg: arg, item: item, conversation: conversation)
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

/// A finished thought, opened: its first `cap` lines, then "Show all". A model can think for
/// minutes; opened whole, a thought outweighs the answer it led to.
struct CappedThought: View {
    let text: String
    static let cap = 12
    @State private var all = false

    /// More than fits under the cap, by lines or by characters (a long unbroken paragraph
    /// wraps to many lines in the measure).
    private var long: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).count > Self.cap || text.count > Self.cap * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(all ? nil : Self.cap)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(all ? "Show less" : "Show all") {
                    withAnimation(.snappy(duration: 0.2)) { all.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
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

    /// Steps that failed or were refused, as the group's sentence counts them ("…, 1 failed").
    private var failures: Int { ActivityGroup(steps: steps).failures }

    var body: some View {
        Group {
            if steps.count == 1, let thought = steps.first, thought.kind == .reasoning {
                // A lone thought's line already says "Thought for 12s"; open, it's the thought,
                // set off like a quote rather than boxed.
                CappedThought(text: thought.text)
                    .padding(.leading, TurnSpace.Inset.roomy)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.separator).frame(width: 2)
                    }
                    .padding(.vertical, TurnSpace.Inset.hair)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        if case .tool("Task", let arg) = step.kind, !step.done {
                            // A running agent keeps its live row open too: what it's doing now,
                            // its plan, Stop, and its run a click away (a plain step row said
                            // only "Agent: …" for as long as it worked).
                            AgentStepRow(arg: arg, item: step, conversation: conversation)
                                .padding(.horizontal, TurnSpace.Inset.card)
                                .padding(.vertical, TurnSpace.Inset.snug)
                        } else {
                            ActivityStepRow(item: step, conversation: conversation, groupFailures: failures)
                        }
                    }
                }
                .padding(.vertical, TurnSpace.Inset.hair)
                .background(Tokens.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: TurnSpace.Card.nestedRadius))
            }
        }
    }
}

/// One step: "Read PaneView.swift", "Ran xcodebuild test · passed". Opens to the output.
struct ActivityStepRow: View {
    let item: ItemState
    let conversation: Conversation
    /// How many failures the step's group carries (the collapsed line ends "N failed"): when
    /// this step is the only one, its own "· failed" would say it again. 0 outside a group.
    var groupFailures: Int = 0
    /// Opened. Not private so snapshots can render it open.
    @State var expanded = false

    /// The row stays quiet about a failure the group's sentence already carries: one failure,
    /// this step, in a group whose sentence ends "1 failed".
    private var groupSaysFailed: Bool { groupFailures == 1 }

    private var name: String {
        if case .tool(let name, _) = item.kind { name } else { "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: TurnSpace.Inset.snug) {
                    // Like the web: the tool's glyph, then its verb, then what it touched.
                    Image(systemName: ToolLook.icon(name))
                        .font(.frog(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    ToolLook.title(rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcome
                    streaming
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
        // A failure opens by itself, as on the web: what went wrong is the point of the row.
        .onAppear { if item.result?.outcome == .error, !groupSaysFailed { expanded = true } }
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

    /// A running row's subtle hint that output is streaming (its newest line shows below), so
    /// a silent-looking wait reads as live. No per-step clock: the app keeps one, the turn's
    /// live status row (`LiveStatus`).
    @ViewBuilder
    private var streaming: some View {
        if !item.done, !item.output.isEmpty {
            Image(systemName: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Output is streaming")
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch item.kind {
        case .reasoning:
            CappedThought(text: item.text)
        case .tool("Task", let arg):
            // The row above already says "Agent: X · failed"; opened, its report.
            AgentReport(arg: arg, item: item, conversation: conversation)
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

    /// How it went, after the name: "· passed", "+3 −1", "Read 8 lines". A failure is said
    /// once: when this step is the only failure of its group, the group's sentence already
    /// ends "1 failed" and the row's red word would say it again — the row stays quiet.
    @ViewBuilder
    private var outcome: some View {
        if name == "Task", !item.done, let plan = item.subagent?.plan {
            // An agent at work: how far along its own plan is.
            Text("· \(plan.done)/\(plan.total)").foregroundStyle(.tertiary).monospacedDigit()
        } else if let r = item.result {
            let tests = (name == "Bash" || name == "!") && ActivityWords.isTest(item.arg)
            switch r.outcome {
            case .denied: Text("· denied").foregroundStyle(.orange)
            case .skipped: Text("· skipped").foregroundStyle(.tertiary)
            case .error where r.display?.hasPrefix("refused: repeated") == true:
                Text("· repeated call refused").foregroundStyle(.red)
            case .error where ToolResultWords.errorLabel(r.display) == "No folder open":
                // A chat with no folder: the model reached for a file or shell tool it doesn't have.
                Text("· no folder open").foregroundStyle(.orange)
            case .error where ToolResultWords.errorLabel(r.display) == "Not available":
                Text("· not available").foregroundStyle(.orange)
            case .error where groupSaysFailed:
                EmptyView()
            case .error:
                // As on the web: a red tag, and the output opens by itself (see `body`).
                FailedTag()
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
            BreathingDot(live: true)
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

/// The web's tool line, natively: one glyph per tool, the verb in the primary color and
/// the rest (path, command, query) quieter.
enum ToolLook {
    static func icon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "!": "terminal"
        case "read": "doc"
        case "write": "doc.text"
        case "edit", "multiedit": "pencil"
        case "grep": "magnifyingglass"
        case "glob": "folder"
        case "webfetch", "websearch": "globe"
        case "todowrite": "checklist"
        case "settitle", "renamesession": "textformat"
        case "task": "person.2"
        default: "wrench.and.screwdriver"
        }
    }

    static func title(_ text: String) -> Text {
        let lead = text.hasPrefix("Searched the web for ") ? "Searched the web for" : String(text.prefix { $0 != " " })
        let rest = text.dropFirst(lead.count)
        return Text(lead).foregroundStyle(.primary) + Text(rest)
    }
}

/// A finished step as the web says it: an icon, a past-tense verb, the argument in mono, and
/// what came of it (matches, a diff, a failure).
struct VerbLine: Equatable {
    var icon: String
    var verb: String
    var arg: String?
    var detail: String?
    var diff: (added: UInt32, removed: UInt32)?
    var failed = false
    /// A thought: quieter, no icon.
    var quiet = false
    /// The step it says, for putting a failed command's output under its own line.
    var itemID: String?

    static func == (a: VerbLine, b: VerbLine) -> Bool {
        a.icon == b.icon && a.verb == b.verb && a.arg == b.arg && a.detail == b.detail
            && a.diff?.added == b.diff?.added && a.diff?.removed == b.diff?.removed && a.failed == b.failed
    }

    /// A group's lines: a thought only when nothing else happened, repeated plan updates once.
    static func lines(_ steps: [ItemState]) -> [VerbLine] {
        let hasTools = steps.contains { if case .tool = $0.kind { true } else { false } }
        var out: [VerbLine] = []
        for step in steps {
            guard let v = of(step, alone: !hasTools) else { continue }
            if v.verb == "Updated the plan", out.contains(where: { $0.verb == v.verb }) { continue }
            out.append(v)
        }
        return out
    }

    static func of(_ item: ItemState, alone: Bool = true) -> VerbLine? {
        switch item.kind {
        case .reasoning:
            guard alone else { return nil }
            return VerbLine(icon: "", verb: item.duration.map { "Thought for \(ActivityWords.duration($0))" } ?? "Thought", quiet: true)
        case .message, .notice:
            return nil
        case .tool(let name, let arg):
            let failed = item.result.map { $0.outcome == .error || $0.outcome == .denied } ?? false
            var v = VerbLine(icon: ToolLook.icon(name), verb: "Used \(ToolIcon.title(name))", arg: arg.isEmpty ? nil : short(arg), failed: failed)
            v.itemID = item.id
            switch name {
            case "Read": v.verb = "Read"
            case "Grep", "Glob":
                v.verb = "Searched for"
                let n = item.output.split(separator: "\n", omittingEmptySubsequences: true).count
                if item.result?.outcome == .ok, !item.output.isEmpty { v.detail = "\(n) match\(n == 1 ? "" : "es")" }
            case "Edit", "MultiEdit":
                v.verb = "Edited"
                v.diff = item.result?.diff.map { ($0.added, $0.removed) }
            case "Write":
                v.verb = item.result?.diff?.created == true ? "Created" : "Wrote"
                v.diff = item.result?.diff.map { ($0.added, $0.removed) }
            case "Bash", "!":
                v.verb = "Ran"
                v.arg = arg.split(separator: "\n").first.map { String($0.prefix(120)) }
            case "WebFetch":
                v.verb = "Fetched"
                v.arg = URL(string: arg)?.host() ?? arg
            case "WebSearch": v.verb = "Searched the web for"
            case "Task": v.verb = "Ran an agent"; v.arg = arg.isEmpty ? nil : arg
            case "TodoWrite": v.verb = "Updated the plan"; v.arg = nil
            case "Diagram": v.verb = "Drew"; if arg.isEmpty { v.verb = "Drew a diagram" }
            case "Visualize": v.verb = "Made a visual"; v.arg = nil
            case "VisualGuide": v.verb = "Read the visual guide"; v.arg = nil
            case "Present": v.verb = "Showed results"; v.arg = nil
            case "Ask": v.verb = "Asked you"; v.arg = nil
            case "Skill": v.verb = "Used the skill"
            case "UseFolder": v.verb = "Moved to"
            default: break
            }
            return v
        }
    }

    /// A path from its repo down, not from /Users.
    private static func short(_ arg: String) -> String {
        guard arg.hasPrefix("/") else { return arg }
        let parts = arg.split(separator: "/")
        return parts.count > 3 ? parts.suffix(3).joined(separator: "/") : arg
    }
}

struct VerbLineView: View {
    let line: VerbLine

    var body: some View {
        if line.quiet {
            Text(line.verb)
                .font(.callout)
                .foregroundStyle(Tokens.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                text
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if line.failed { FailedTag() }
            }
        }
    }

    private var text: Text {
        var t = Text(Image(systemName: line.icon)).foregroundStyle(Tokens.textTertiary)
            + Text(verbatim: "  ")
            + Text(line.verb).foregroundStyle(Tokens.textSecondary)
        if let arg = line.arg {
            t = t + Text(verbatim: " ") + Text(verbatim: arg)
                .font(.frog(size: Tokens.Size.status, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        if let d = line.detail {
            t = t + Text(verbatim: " · \(d)").foregroundStyle(Tokens.textTertiary)
        }
        if let diff = line.diff {
            t = t + Text(verbatim: " +\(diff.added)").foregroundStyle(.green).monospacedDigit()
                + Text(verbatim: " −\(diff.removed)").foregroundStyle(.red).monospacedDigit()
        }
        return t
    }
}

/// A failed step's tag, as on the web: "failed" in red on a faint red plate.
struct FailedTag: View {
    var body: some View {
        Text("failed")
            .font(.frog(size: 11, weight: .medium))
            .foregroundStyle(Tokens.fail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Tokens.fail.opacity(0.14), in: .rect(cornerRadius: 5))
    }
}

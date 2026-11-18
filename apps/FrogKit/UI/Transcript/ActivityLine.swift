import SwiftUI

/// What frog did between two pieces of text: one line per finished step, four or more in a row
/// folded into one, a thought on a line of its own (docs/design/transcript/spec.md, "Lines").
/// Lines in a run touch; each opens on its own.
struct ActivityLine: View {
    @Environment(\.pinsQuestions) private var pinsQuestions
    @Environment(\.turnSpace) private var space
    let group: ActivityGroup
    let conversation: Conversation
    /// The turn is running: a long thought streams below the line, and a subagent shows live.
    var live = false
    var verbosity: Verbosity = .normal

    init(group: ActivityGroup, conversation: Conversation, live: Bool = false, verbosity: Verbosity = .normal) {
        self.group = group
        self.conversation = conversation
        self.live = live
        self.verbosity = verbosity
    }

    /// The group is only thinking: each finished thought is a line ("Thought for 12s").
    private var thoughts: [ItemState] {
        let hasTools = group.steps.contains { if case .tool = $0.kind { true } else { false } }
        return hasTools ? [] : group.done.filter { $0.kind == .reasoning }
    }

    /// A long thought on a line of its own gets a gist.
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
        let runs = StepRuns.of(group.steps)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(thoughts) { t in
                ThoughtLineView(item: t, gist: t.id == thought?.id ? gist : nil, open: verbosity == .verbose)
            }
            ForEach(runs) { run in
                switch run {
                case .step(let item): StepLineView(item: item, conversation: conversation)
                case .fold(let steps): FoldLineView(steps: steps, conversation: conversation, open: verbosity == .verbose)
                }
            }
            if live, let now = group.current {
                liveStep(now)
            }
            if !pinsQuestions, let p = conversation.permission, group.steps.contains(where: { $0.needsPermission && $0.id == p.item }) {
                // A box: a block's gap from any line above it.
                PermissionCard(request: p, conversation: conversation)
                    .padding(.top, runs.isEmpty && thoughts.isEmpty ? 0 : space.block)
            }
        }
        // Asked for once the line shows (the lazy transcript only builds what's near the view).
        .task(id: thought?.id) {
            guard let t = thought else { return }
            Gists.shared.request(session: conversation.sessionID, item: t.id, thought: t.text)
        }
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

/// A model on this Mac getting ready for its first answer, read from the engine's progress
/// label, in words true to the kind: a downloaded model is read into memory ("loading <repo>",
/// named the way the model menu names it); Apple Intelligence is the system's own model and is
/// only started ("starting Apple Intelligence").
struct ModelLoad: Equatable {
    enum Kind { case downloaded, system }
    let name: String
    let kind: Kind

    var title: String { kind == .system ? "Starting \(name)" : "Loading \(name) into memory" }
    var caption: String? { kind == .system ? nil : "Starting the first response" }
    var symbol: String { kind == .system ? "sparkles" : "cpu" }

    @MainActor
    init?(label: String) {
        if label.caseInsensitiveCompare("starting Apple Intelligence") == .orderedSame
            || label.caseInsensitiveCompare("loading apple") == .orderedSame {  // an older engine's label
            self.init(name: "Apple Intelligence", kind: .system)
            return
        }
        guard label.lowercased().hasPrefix("loading ") else { return nil }
        let repo = String(label.dropFirst("loading ".count))
        guard !repo.isEmpty else { return nil }
        self.init(name: ModelIdentity.rowName("\(ProviderID.local)/\(repo)"), kind: .downloaded)
    }

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Any progress label as a line to show: a model getting ready in its words, anything else
    /// capitalized.
    @MainActor
    static func words(_ label: String) -> String {
        ModelLoad(label: label)?.title ?? label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// A model getting ready before the first answer: one card, with an indeterminate sweep (neither
/// tang's weight load nor the system model's start reports how far along it is, so no made-up
/// percentage). It is the turn's only loading line: `WorkingIndicator` steps aside for it.
struct ModelLoadingStatus: View {
    let load: ModelLoad
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(since))
            VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
                HStack(spacing: TurnSpace.Inset.row) {
                    Image(systemName: load.symbol)
                        .foregroundStyle(.tint)
                    Text(load.title)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Text(Self.elapsed(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ModelLoadBar(elapsed: elapsed)
                if let caption = load.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(load.title)
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

    /// Tools whose result is a sentence, not a payload. A `SendMessage` result is one line
    /// ("Sent to ops; delivered"); burying it two clicks down behind its own label repeated is
    /// not "show more", it's hiding a short answer. These carry their result on the row itself
    /// and open to plain text rather than a terminal block.
    ///
    /// The other half of the rule is everything else: a command's output, a file's contents, a
    /// search's matches — a payload, which stays behind the row's chevron.
    static let inlineResults: Set<String> = [
        "SendMessage", "Ask", "TodoWrite", "Skill", "UseFolder",
        "RenameSession", "MoveSession", "ArchiveSession", "UnarchiveSession", "ListSessions",
    ]

    /// Whether a tool's result reads as a sentence with its row (see `inlineResults`).
    static func isInline(_ name: String) -> Bool { inlineResults.contains(name) }

    /// How much of a short result a row's own line shows before it's worth a click.
    static let lineCap = 90

    /// A short result in full: what sits under a row that opened to a sentence rather than a
    /// terminal block. `ListSessions` is the exception, whose page of JSON the row summarises.
    static func result(name: String, display: String?, output: String) -> String {
        whole(display: display, output: output).map { sessions(name, $0) ?? $0 } ?? ""
    }

    /// The phrase a short result reads as on the row itself: the engine's display when it sent
    /// one ("chose: Truncate"), else the first line of the result ("Sent to ops (…); delivered").
    /// Clipped, since the row is one line; "" when there's nothing to say.
    static func line(name: String, display: String?, output: String) -> String {
        guard let full = whole(display: display, output: output), !full.isEmpty else { return "" }
        if let n = sessions(name, full) { return n }
        let first = full.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? full
        // A result is often a sentence followed by advice ("Sent to ops; delivered. It reads
        // the message at its next boundary…"): the first sentence is the meat, and the rest is
        // behind the row. Its full stop is dropped — the row sets it off with " · ", and a line
        // ending in a period under a verb reads as the end of the whole thought.
        if let stop = sentenceEnd(first), first.distance(from: first.startIndex, to: stop) <= lineCap {
            let sentence = first[..<stop].trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            if !sentence.isEmpty { return sentence }
        }
        return first.count > lineCap ? String(first.prefix(lineCap - 1)) + "…" : first
    }

    /// Where a result's first sentence ends, when it's worth cutting there (a ". " — not a
    /// version number's dot, hence the following space).
    private static func sentenceEnd(_ s: String) -> String.Index? {
        guard s.count > 24 else { return nil }
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "." || c == "!" || c == "?" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == " " { return next }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Whether the line says the whole of it: nothing is left behind the row, so it gets no
    /// chevron (a click that reveals nothing is the same wasted click). True when the line is
    /// the whole result, not a first-sentence cut or a clip of it.
    static func fits(name: String, display: String?, output: String) -> Bool {
        guard let full = whole(display: display, output: output), !full.isEmpty else { return true }
        return line(name: name, display: display, output: output) == full
    }

    /// "12 sessions" from `ListSessions`' JSON array: the result there is a page of JSON, whose
    /// first line is "[" — the count is the only thing worth putting on the row.
    static func sessions(_ name: String, _ output: String) -> String? {
        guard name == "ListSessions",
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return "\(rows.count) session\(rows.count == 1 ? "" : "s")"
    }

    private static func whole(display: String?, output: String) -> String? {
        let text = (display.flatMap { $0.isEmpty ? nil : $0 } ?? output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

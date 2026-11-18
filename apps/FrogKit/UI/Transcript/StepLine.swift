import SwiftUI

/// One step as its line (docs/design/transcript/spec.md, phase 1: "Lines", "Failure", "Test
/// runs"): mark, verb, object, then its result at the right in `meta`. The words come from
/// `Verbs` (generated from docs/design/transcript/verbs.json, the table the web's rows.ts reads),
/// and the rules are the web's (`lineOf` in apps/web/src/ui/rows.ts), so both apps say the same.
struct StepLine: Equatable {
    enum State: Equatable { case run, ok, failed, denied }
    enum Kind: Equatable { case command, edit, read, search, web, other }
    struct Diff: Equatable { let added: UInt32; let removed: UInt32 }

    var name: String
    var kind: Kind
    var state: State
    /// In `muted` ("Ran", "Failed" in `warn`, "Didn't run"); empty when a gist is the line.
    var verb: String
    /// What it acted on, in `fg`; mono for code, paths, commands and tool names.
    var object: String
    var mono: Bool
    /// The engine's gist, when it is the whole line (a finished, successful step).
    var gist: String
    /// At the right, in `meta`: "54 lines", "10 of 11 · 9.0s", "you said no".
    var result: String
    /// An edit's counts, drawn green and red.
    var diff: Diff?
    /// The full argument when the line shows less of it (a `cd` prefix dropped, a host).
    var title: String

    /// The line's words as the parity metrics read them: verb, gist, object and result joined
    /// by one space ("Edited src/retry.rs +3 −2").
    var text: String {
        let counts = diff.map { "+\($0.added) −\($0.removed)" } ?? ""
        return [verb, gist, object, result, counts].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let kinds: [String: Kind] = [
        "bash": .command, "!": .command, "edit": .edit, "multiedit": .edit, "write": .edit, "read": .read,
        "grep": .search, "glob": .search, "codemap": .search, "webfetch": .web, "websearch": .web,
    ]

    /// The line for a tool step; nil for anything else.
    static func of(_ item: ItemState) -> StepLine? {
        guard case .tool(let name, let rawArg) = item.kind else { return nil }
        let look = Verbs.look(name)
        let kind = kinds[name.lowercased()] ?? .other
        let state: State = !item.done ? .run
            : item.result?.outcome == .error ? .failed
            : item.result?.outcome == .denied ? .denied : .ok
        let arg = rawArg.trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = item.result?.diff
        var object = ""
        var place = ""
        var title = ""
        switch look.object {
        case .command:
            let cd = splitCd(arg)
            object = firstLine(cd.command)
            if cd.command != arg { place = cd.place ?? ""; title = arg }
            if object.count > 120 { object = String(object.prefix(119)) + "…"; title = arg }
        case .host:
            object = URL(string: arg)?.host() ?? arg
            if object.isEmpty { object = arg }
            if object != arg { title = arg }
        case .tool:
            object = toolTitle(name)
            title = arg
        case .none:
            break
        default:
            object = firstLine(arg)
        }
        if let diff, look.object == .path, object.isEmpty { object = diff.path }
        let gist = state == .ok ? (item.gist ?? "") : ""
        let verb: String = switch state {
        case .failed: Verbs.failed
        case .denied: Verbs.denied
        case .run: look.live
        case .ok: diff?.created == true && look.created != nil ? look.created! : look.past
        }
        let time = item.duration.map { duration($0) } ?? ""
        var result = ""
        switch state {
        case .denied:
            result = Verbs.deniedResult
        case .run:
            break
        case .ok, .failed:
            if let tests = item.result?.tests {
                result = ["\(tests.passed) of \(tests.total)", time].filter { !$0.isEmpty }.joined(separator: " · ")
            } else if kind == .command {
                result = place.isEmpty ? "" : "in \(place)"
            } else if diff == nil {
                result = fromDisplay(item.result?.display, past: look.past)
            }
        }
        // A tool whose result is a sentence says it on the line, with no click at all.
        // A result that opens by repeating the line ("Moved to /tmp/demo" under "Moved to
        // /tmp/demo") gives only the rest, or nothing.
        if state == .ok, ToolLook.isInline(name), diff == nil {
            var said = ToolLook.line(name: name, display: item.result?.display, output: item.result?.output ?? item.output)
            if !said.isEmpty {
                let lineText = (verb + " " + object).trimmingCharacters(in: .whitespaces)
                for prefix in [lineText, verb] where !prefix.isEmpty && said.lowercased().hasPrefix(prefix.lowercased()) {
                    said = String(said.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ·:—-"))
                    break
                }
                result = said
            }
        }
        return StepLine(
            name: name, kind: kind, state: state,
            verb: gist.isEmpty ? verb : "", object: gist.isEmpty ? object : "",
            mono: look.object.mono, gist: gist, result: result,
            diff: diff.flatMap { d in state == .denied || state == .run ? nil : Diff(added: d.added, removed: d.removed) },
            title: title)
    }

    /// "github › list_issues" for `mcp__github__list_issues`: a tool the table doesn't know, by name.
    static func toolTitle(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) › \(parts.dropFirst().joined(separator: "__"))" : String(name.dropFirst(5))
    }

    /// "0.8s", "9.0s", "12s", "2m 5s": a step's time, in the web's words (rows.ts `duration`).
    static func duration(_ secs: TimeInterval) -> String {
        if secs < 10 { return String(format: "%.1fs", secs) }
        if secs < 60 { return "\(Int(secs.rounded()))s" }
        return "\(Int(secs / 60))m \(Int(secs.truncatingRemainder(dividingBy: 60).rounded()))s"
    }

    /// The result the engine's own display gives, without the verb it repeats: "Read 54 lines"
    /// under "Read src/a.rs" is "54 lines". Nothing is parsed out of the output.
    static func fromDisplay(_ display: String?, past: String) -> String {
        let d = (display ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !d.isEmpty else { return "" }
        return d.lowercased().hasPrefix(past.lowercased() + " ") ? String(d.dropFirst(past.count + 1)) : d
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? s
    }

    /// A command that opens with `cd <dir> &&` (or `;`), split into the rest and a short name
    /// for the place: a worktree's own name (`…/worktrees/audit334` → "audit334"), or nil for
    /// anywhere else (the session root on every row is noise). Anything else comes back whole.
    static func splitCd(_ command: String) -> (command: String, place: String?) {
        let trimmed = command.drop { $0 == " " }
        guard trimmed.hasPrefix("cd ") else { return (command, nil) }
        var rest = trimmed.dropFirst(3).drop { $0 == " " }
        var dir = ""
        if let q = rest.first, q == "\"" || q == "'" {
            guard let end = rest.dropFirst().firstIndex(of: q) else { return (command, nil) }
            dir = String(rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[rest.index(after: end)...]
        } else {
            let end = rest.firstIndex { $0 == " " || $0 == ";" || $0 == "&" || $0 == "\n" } ?? rest.endIndex
            dir = String(rest[..<end])
            rest = rest[end...]
        }
        rest = rest.drop { $0 == " " }
        if rest.hasPrefix("&&") { rest = rest.dropFirst(2) } else if rest.hasPrefix(";") { rest = rest.dropFirst() } else { return (command, nil) }
        let cmd = rest.drop { $0 == " " }
        guard !dir.isEmpty, !cmd.isEmpty else { return (command, nil) }
        let parts = dir.split(separator: "/")
        let place = parts.firstIndex(of: "worktrees").flatMap { i in i + 1 < parts.count ? String(parts[i + 1]) : nil }
        return (String(cmd), place)
    }
}

// MARK: - Folds

/// Four or more finished steps in a row, with no prose between, fold into one line (spec,
/// "Folds"). A failed step never folds and splits the run around it; a running step breaks it.
enum StepRuns {
    static let foldAt = 4

    enum Run: Identifiable {
        case step(ItemState)
        case fold([ItemState])

        var id: String {
            switch self {
            case .step(let s): s.id
            case .fold(let steps): "fold-" + (steps.first?.id ?? "")
            }
        }
    }

    /// The finished tool steps of a group as lines and folds. Thoughts between steps don't draw
    /// (the Mac's rule: a thought beside tools says nothing) and don't break a run.
    static func of(_ steps: [ItemState]) -> [Run] {
        var out: [Run] = []
        var run: [ItemState] = []
        func flush() {
            if run.count >= foldAt { out.append(.fold(run)) } else { out += run.map(Run.step) }
            run = []
        }
        for step in steps {
            guard case .tool = step.kind else { continue }
            guard step.done else { flush(); continue }
            if step.result?.outcome == .error { flush(); out.append(.step(step)) } else { run.append(step) }
        }
        flush()
        return out
    }

    /// A fold's time: the first step's start to the last one's end.
    static func time(_ steps: [ItemState]) -> String {
        let starts = steps.compactMap(\.startedAt), ends = steps.compactMap(\.endedAt)
        guard let a = starts.min(), let b = ends.max() else { return "" }
        return StepLine.duration(b.timeIntervalSince(a))
    }
}

/// A failed command opens itself once (spec, "Failure"): the first time it is drawn failed it
/// starts open, and from then on it is however the person last left it, across remounts (the
/// lazy transcript rebuilds rows as they scroll back into view).
@MainActor
enum SelfOpening {
    private static var remembered: [String: Bool] = [:]

    static func opens(_ id: String, _ line: StepLine) -> Bool {
        if let was = remembered[id] { return was }
        guard line.state == .failed, line.kind == .command else { return false }
        remembered[id] = true
        return true
    }

    /// The person opened or closed a row: remembered for one that opened itself.
    static func remember(_ id: String, open: Bool) {
        if remembered[id] != nil { remembered[id] = open }
    }

    /// For tests.
    static func reset() { remembered = [:] }
}

// MARK: - The left edge

/// Where the transcript's text starts (spec, "Measure and the left edge"). A line's mark hangs
/// `Layout.hang` into the gutter, so verbs, thoughts, the footer and prose share one edge. When
/// the gutter is narrower than the hang (a narrow pane or split), marks come inside the column
/// and every text row indents by the hang together.
struct TranscriptEdge: Equatable {
    var gutter: CGFloat
    /// How far text rows start in from the column's edge: 0, or the hang in a narrow pane.
    var indent: CGFloat

    static let hang = TranscriptEdge(gutter: Tokens.Transcript.Layout.gutter, indent: 0)

    /// Panes narrower than this get the narrow gutter (the web's `INSET_BELOW`).
    static let insetBelow: CGFloat = 480

    static func of(paneWidth: CGFloat) -> TranscriptEdge {
        let L = Tokens.Transcript.Layout.self
        let gutter = paneWidth < insetBelow ? L.gutterNarrow : L.gutter
        return TranscriptEdge(gutter: gutter, indent: gutter < L.hang ? L.hang : 0)
    }
}

extension EnvironmentValues {
    @Entry var transcriptEdge = TranscriptEdge.hang
}

// MARK: - Views

private enum LineType {
    static let status = Tokens.Transcript.status
    static let meta = Tokens.Transcript.meta
    static var sans: Font { .frog(size: status.size) }
    static var mono: Font { .frog(size: status.mono, design: .monospaced) }
    static var result: Font { .frog(size: meta.size).monospacedDigit() }
}

/// A line's frame: the mark hung in the gutter, the plate on hover, the row's height. Shared by
/// steps, folds and thoughts so they line up.
struct LineFrame<Mark: View, Content: View>: View {
    var hovered: Bool
    @ViewBuilder var mark: Mark
    @ViewBuilder var content: Content
    @Environment(\.turnSpace) private var space
    @Environment(\.transcriptEdge) private var edge

    var body: some View {
        let L = Tokens.Transcript.Layout.self
        HStack(spacing: TurnSpace.Inset.snug) { content }
            .frame(maxWidth: .infinity, minHeight: space.gaps.row, maxHeight: space.gaps.row, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: L.plateRadius)
                    .fill(Tokens.hover)
                    .frame(height: L.plate)
                    .padding(.horizontal, -L.plateBleed)
                    .opacity(hovered ? 1 : 0)
            }
            .overlay(alignment: .leading) {
                mark
                    .frame(width: L.mark, height: L.mark)
                    .foregroundStyle(Tokens.textTertiary)
                    .offset(x: -L.hang)
            }
            .padding(.leading, edge.indent)
            .contentShape(.rect)
    }
}

/// One finished step as its line. One click (or Return) opens it: a command's last lines, an
/// edit's change, a search's results. A read has nothing to open, unless it failed.
struct StepLineView: View {
    let item: ItemState
    let conversation: Conversation
    @State private var open: Bool
    @State private var hovered = false

    /// `startOpen`: drawn opened (tests and snapshots).
    init(item: ItemState, conversation: Conversation, startOpen: Bool = false) {
        self.item = item
        self.conversation = conversation
        let line = StepLine.of(item)
        _open = State(initialValue: startOpen || (line.map { SelfOpening.opens(item.id, $0) } ?? false))
    }

    private var line: StepLine? { StepLine.of(item) }

    /// The line says the whole of a short result: nothing behind it to open.
    private func whole(_ line: StepLine) -> Bool {
        guard line.state == .ok, ToolLook.isInline(line.name), line.diff == nil else { return false }
        return ToolLook.fits(name: line.name, display: item.result?.display, output: item.result?.output ?? item.output)
    }

    private func opens(_ line: StepLine) -> Bool {
        let output = (item.result?.output ?? item.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return !whole(line) && (line.kind != .read || line.state == .failed) && line.state != .run
            && (item.result?.diff != nil || !output.isEmpty || item.result?.tests != nil || line.state == .failed
                || !line.gist.isEmpty || !line.title.isEmpty || !item.displayImages.isEmpty)
    }

    var body: some View {
        if let line {
            VStack(alignment: .leading, spacing: 0) {
                row(line)
                if open, opens(line) {
                    OpenedStep(item: item, line: line, conversation: conversation)
                        .padding(.leading, edgeIndent)
                        .transition(.opacity)
                }
            }
            .onChange(of: line.state) { _, s in
                // A step that fails while drawn (it mounted running) opens when it turns failed, once.
                if s == .failed, SelfOpening.opens(item.id, line) { open = true }
            }
        }
    }

    @Environment(\.transcriptEdge) private var edge
    private var edgeIndent: CGFloat { edge.indent }

    private func row(_ line: StepLine) -> some View {
        Button {
            guard opens(line) else { return }
            SelfOpening.remember(item.id, open: !open)
            withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
            LineFrame(hovered: hovered && opens(line)) {
                Image(systemName: ToolLook.icon(line.name)).font(.frog(size: 11))
            } content: {
                words(line)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { hovered = $0 }
        .overlay(alignment: .trailing) {
            if hovered, line.kind == .command, line.state != .run, !item.arg.isEmpty {
                MessageAction(title: "Copy command", symbol: "doc.on.doc") { Clipboard.copy(item.arg) }
                    .background(Tokens.canvas)
            }
        }
        .help(line.title.isEmpty ? (line.gist.isEmpty ? "" : item.arg) : line.title)
        .metricsRow(.line, line.text, key: item.id, fontSize: line.verb.isEmpty && line.gist.isEmpty && line.mono
                    ? LineType.status.mono : LineType.status.size)
    }

    @ViewBuilder
    private func words(_ line: StepLine) -> some View {
        if !line.gist.isEmpty {
            Text(line.gist).font(LineType.sans).foregroundStyle(Tokens.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .metricsFirstWord()
        } else {
            if !line.verb.isEmpty {
                Text(line.verb).font(LineType.sans)
                    .foregroundStyle(line.state == .failed ? Tokens.warn : line.state == .run ? Tokens.text : Tokens.textSecondary)
                    .fixedSize()
                    .metricsFirstWord()
            }
            if !line.object.isEmpty {
                Text(line.object).font(line.mono ? LineType.mono : LineType.sans).foregroundStyle(Tokens.text)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
        Spacer(minLength: TurnSpace.Inset.row)
        if !line.result.isEmpty {
            Text(line.result).font(LineType.result).foregroundStyle(Tokens.textTertiary)
                .lineLimit(1).truncationMode(.tail)
        }
        if let d = line.diff {
            (Text(verbatim: "+\(d.added)").foregroundStyle(Tokens.accent)
                + Text(verbatim: " −\(d.removed)").foregroundStyle(Tokens.warn))
                .font(LineType.result)
                .fixedSize()
        }
        if item.sandboxEscaped {
            Text(verbatim: "outside the sandbox").font(LineType.result).foregroundStyle(Tokens.textTertiary).fixedSize()
        }
    }
}

/// What an opened step shows under its line.
struct OpenedStep: View {
    let item: ItemState
    let line: StepLine
    let conversation: Conversation

    /// A command's last lines before Show all.
    static let tail = 12
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
            if (!line.gist.isEmpty || !line.title.isEmpty), !item.arg.isEmpty {
                Text(item.arg).font(.frog(size: Tokens.Transcript.status.mono, design: .monospaced))
                    .foregroundStyle(Tokens.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Tokens.Transcript.status.line)
            }
            if let names = item.result?.tests?.failedNames, !names.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(names, id: \.self) { n in
                        Text(n).frame(height: Tokens.Transcript.status.line)
                    }
                }
                .font(.frog(size: Tokens.Transcript.status.mono, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .accessibilityLabel("Failing tests")
            }
            content
            if let why = item.autoReason {
                Label("Auto: \(why)", systemImage: "wand.and.sparkles")
                    .font(.frog(size: Tokens.Transcript.meta.size))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
                    .help("Auto mode's classifier let this run without asking")
            }
        }
        .padding(.top, TurnSpace.Inset.tight)
        .padding(.bottom, TurnSpace.Inset.row)
    }

    private var output: String { (item.result?.display ?? item.result?.output ?? item.output).trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private var content: some View {
        if line.kind == .command {
            command
        } else if line.name == "Task" {
            // An agent's report reads like an answer, with its run a click away.
            AgentReport(arg: item.arg, item: item, conversation: conversation)
        } else if !item.displayImages.isEmpty {
            ToolImages(images: item.displayImages, preview: !item.done)
        } else if ToolLook.isInline(line.name) || line.kind == .web {
            Text(output.isEmpty ? "No output." : output)
                .font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
            ToolDetail(name: line.name, item: item, root: conversation.folder.path)
        }
    }

    /// A command's last lines in a well, then where it ran, Show all and Copy.
    private var command: some View {
        let lines = output.isEmpty ? [] : output.components(separatedBy: "\n")
        let shown = all || lines.count <= Self.tail ? lines : Array(lines.suffix(Self.tail))
        return VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
            if lines.isEmpty {
                Text("No output.").font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textTertiary)
            } else {
                ScrollView(.vertical) {
                    Text(shown.joined(separator: "\n"))
                        .font(.frog(size: Tokens.Transcript.status.mono, design: .monospaced))
                        .lineSpacing(Tokens.Transcript.status.line - monoLineHeight(Tokens.Transcript.status.mono))
                        .padding(.vertical, (Tokens.Transcript.status.line - monoLineHeight(Tokens.Transcript.status.mono)) / 2)
                        .foregroundStyle(Tokens.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, TurnSpace.Inset.row)
                        .padding(.horizontal, TurnSpace.Inset.card)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .background(Tokens.well, in: .rect(cornerRadius: TurnSpace.Card.nestedRadius))
            }
            HStack(spacing: TurnSpace.Inset.row) {
                Text(conversation.cloudSession != nil ? "Ran in your Frog Cloud sandbox" : "Ran on this Mac")
                if lines.count > Self.tail {
                    Button(all ? "Show less" : "Show all \(lines.count) lines") { all.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Tokens.textSecondary)
                }
                if !output.isEmpty {
                    MessageAction(title: "Copy output", symbol: "doc.on.doc") { Clipboard.copy(output) }
                }
            }
            .font(.frog(size: Tokens.Transcript.meta.size))
            .foregroundStyle(Tokens.textTertiary)
            .frame(height: Tokens.Transcript.Layout.plate)
        }
    }
}

/// Four or more finished steps folded into one line: a chevron, "12 steps", the time. Opened,
/// it lists its steps.
struct FoldLineView: View {
    let steps: [ItemState]
    let conversation: Conversation
    /// Verbose shows every step: it opens (and closes) with the setting.
    var verbose = false
    @State private var open: Bool
    @State private var hovered = false

    init(steps: [ItemState], conversation: Conversation, verbose: Bool = false) {
        self.steps = steps
        self.conversation = conversation
        self.verbose = verbose
        _open = State(initialValue: verbose)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let words = "\(steps.count) steps"
            let time = StepRuns.time(steps)
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                LineFrame(hovered: hovered) {
                    Image(systemName: "chevron.right").font(.frog(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                } content: {
                    Text(words).font(LineType.sans).foregroundStyle(Tokens.textSecondary).metricsFirstWord()
                    Spacer(minLength: TurnSpace.Inset.row)
                    if !time.isEmpty { Text(time).font(LineType.result).foregroundStyle(Tokens.textTertiary) }
                }
            }
            .buttonStyle(.plain)
            .focusable()
            .onHover { hovered = $0 }
            .help(open ? "Hide steps" : "Show steps")
            .metricsRow(.fold, [words, time].filter { !$0.isEmpty }.joined(separator: " "), key: "fold-" + (steps.first?.id ?? ""),
                        fontSize: LineType.status.size)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { StepLineView(item: $0, conversation: conversation) }
                }
                .environment(\.metricsHidden, true)
                .transition(.opacity)
            }
        }
        .onChange(of: verbose) { _, v in open = v }
    }
}

/// A thought: one quiet line with a chevron, opening to what it thought. Today's words ("Thought
/// for 12s"); phase 2 replaces the row.
struct ThoughtLineView: View {
    @Environment(\.transcriptEdge) private var edge
    let item: ItemState
    var gist: String?
    /// Verbose shows the thought: it opens (and closes) with the setting.
    var verbose = false
    @State private var open: Bool
    @State private var hovered = false

    init(item: ItemState, gist: String? = nil, verbose: Bool = false) {
        self.item = item
        self.gist = gist
        self.verbose = verbose
        _open = State(initialValue: verbose)
    }

    /// "Thought for 31s" from the engine's think time (started→completed overstates it), or
    /// the item's own times in an old log; "Stopped after 12s" for a think the turn stopped.
    private var words: String { Self.words(item) }

    static func words(_ item: ItemState) -> String {
        let secs = item.thinkMs.map { Double($0) / 1000 } ?? item.duration
        if !item.done {
            let ran = item.startedAt.map { (item.endedAt ?? .now).timeIntervalSince($0) }
            return ran.map { "Stopped after \(ActivityWords.duration($0))" } ?? "Stopped"
        }
        return secs.map { "Thought for \(ActivityWords.duration($0))" } ?? "Thought"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                LineFrame(hovered: hovered) {
                    Image(systemName: "chevron.right").font(.frog(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                } content: {
                    Text(words).font(LineType.sans).foregroundStyle(Tokens.textSecondary).fixedSize().metricsFirstWord()
                    if let gist {
                        Text(verbatim: "· \(gist)").font(LineType.sans).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .focusable()
            .onHover { hovered = $0 }
            .help(open ? "Hide the thought" : "Show the thought")
            .metricsRow(.thought, [words, gist.map { "· \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                        key: item.id, fontSize: LineType.status.size)
            if open {
                ThinkingOutline(item: item)
                    .padding(.leading, edge.indent)
                    .padding(.bottom, TurnSpace.Inset.snug)
                    .transition(.opacity)
            }
        }
        .onChange(of: verbose) { _, v in open = v }
    }
}

/// The sans face's own line height at a size (IBM Plex Sans), like `monoLineHeight`.
func sansLineHeight(_ size: CGFloat) -> CGFloat {
    _ = PlexFonts.registered
    #if os(macOS)
    let f = NSFont(name: "IBM Plex Sans", size: size) ?? .systemFont(ofSize: size)
    // SwiftUI lays a line out on the ascent and descent rounded each (a 14 pt Plex line is 18,
    // not 18.2), so a fixed line box tops up from those.
    return f.ascender.rounded() + (-f.descender).rounded() + f.leading.rounded()
    #else
    let f = UIFont(name: "IBMPlexSans", size: size) ?? .systemFont(ofSize: size)
    return f.lineHeight
    #endif
}

extension View {
    /// Text on a type role's fixed line box (14 / 22, 12.5 / 20…), as CSS sets it: the extra
    /// split above and below, and between wrapped lines.
    func fixedLine(_ role: Tokens.Transcript.Role) -> some View {
        let extra = max(0, role.line - sansLineHeight(role.size))
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// The mono face's own line height at a size, so `lineSpacing` can top it up to a fixed line box.
func monoLineHeight(_ size: CGFloat) -> CGFloat {
    #if os(macOS)
    _ = PlexFonts.registered
    let f = NSFont(name: "IBM Plex Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    return f.ascender.rounded() + (-f.descender).rounded() + f.leading.rounded()
    #else
    _ = PlexFonts.registered
    let f = UIFont(name: "IBMPlexMono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    return f.lineHeight
    #endif
}

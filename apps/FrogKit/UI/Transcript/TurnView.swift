import SwiftUI

/// A turn reads like prose, in the order things happened: what you asked, then text and
/// muted lines for what frog did in between ("Read 3 files, searched for …"), then the files
/// that changed. Cards are only for what needs you or went wrong.
struct TurnActions {
    /// Nil where a turn can't be forked or rewound from (the phone, for now): the actions hide.
    var fork: ((UInt64) -> Void)?
    var rewind: ((UInt64) -> Void)?
    var canRewind: Bool { fork != nil && rewind != nil }
}

/// A turn is rows in the transcript's lazy stack, not one view: its prompt, each piece of the
/// flow (text, an activity line, a visual), and its tail (plan, live status, changes, footer).
/// Only the rows on screen are built, however long the turn, and a long turn scrolls like the
/// transcript does rather than being laid out whole (see `TranscriptRows`).
enum TurnPart {
    case head
    case segment(TurnFlow.Segment)
    case tail
}

struct TurnView: View {
    let turn: TurnState
    let conversation: Conversation
    let actions: TurnActions
    /// Which of the turn's rows this is.
    let part: TurnPart
    /// Space above the row: between turns for a turn's first row, within one for the rest.
    var gap: CGFloat = 0
    /// Show the model/speed footer without hovering (see `TurnFooter.pinned`).
    var pinsFooter = true
    /// The pointer is over what you asked (its actions show) rather than elsewhere in the turn.
    @State private var hoveringPrompt = false
    @State private var confirmRewind = false
    /// False until a just-sent prompt has sprung into place.
    @State private var landed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Verbosity.key) private var defaultVerbosity = Verbosity.standard.rawValue
    @Environment(\.turnSpace) private var space

    @Environment(\.models) private var models
    @Environment(\.transcriptTrack) private var track

    init(turn: TurnState, conversation: Conversation, actions: TurnActions, part: TurnPart, gap: CGFloat = 0, pinsFooter: Bool = true) {
        self.turn = turn
        self.conversation = conversation
        self.actions = actions
        self.part = part
        self.gap = gap
        self.pinsFooter = pinsFooter
        // Only a prompt sent a moment ago flies in; history, replays and a scrolled-back
        // turn are simply there.
        _landed = State(initialValue: !(turn.sentAt.map { Date.now.timeIntervalSince($0) < 1 } ?? false))
    }

    /// The pointer is over this turn, any of its rows (its footer shows).
    private var hovering: Bool { track?.hoveredTurn == turn.id }

    private func hover(_ on: Bool) {
        guard let track else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if on { track.hoveredTurn = turn.id } else if track.hoveredTurn == turn.id { track.hoveredTurn = nil }
        }
    }

    private var running: Bool { !turn.finished && conversation.busy }

    /// The message being written, when it's the turn's last item.
    private var liveAnswerID: String? {
        guard let last = turn.items.last, last.kind == .message, !last.done else { return nil }
        return last.id
    }

    /// The model that answered (or is answering): the prompt takes its place's color.
    private var promptTint: Color {
        guard let spec = turn.usage?.model ?? conversation.status?.model else { return .accentColor }
        return ModelIdentity.of(spec, in: models).place.color
    }

    private var verbosity: Verbosity {
        VerbosityOverrides.shared.level(
            for: conversation.sessionID, default: Verbosity(rawValue: defaultVerbosity) ?? .normal)
    }

    /// The thought streaming now, previewed beside "Thinking…" (verbose shows it in full, below).
    private var thinking: String? {
        guard verbosity == .normal, let last = turn.items.last, last.kind == .reasoning, !last.done else { return nil }
        return last.text
    }

    var body: some View {
        #if DEBUG
        let _ = TranscriptProbe.turn()
        #endif
        let parts = TurnParts(turn)
        VStack(alignment: .leading, spacing: space.inTurn) {
            let lead = TurnLead(turn)
            let flow = TurnFlow(turn.items, showThinking: verbosity.showsThinking)
            if !lead.wakes.isEmpty {
                // Background work finished and the turn opened with it: event rows, not a bubble.
                WakeEventRows(events: lead.wakes, jobs: conversation.jobs)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
            }
            switch lead.opener {
            case .sessionMessages(let delivered):
                // Collapsed like a tool row: who, that it's a message, its first line.
                ForEach(Array(delivered.enumerated()), id: \.offset) { _, message in
                    EventLineView(event: EventLine(message: message))
                }
            case .none:
                EmptyView()
            case .prompt:
                VStack(alignment: .trailing, spacing: 2) {
                    // Messages queued while the last turn ran go together: a bubble each.
                    VStack(alignment: .trailing, spacing: 6) {
                        UserPrompt(text: turn.input, images: turn.images, tint: promptTint)
                        ForEach(Array(turn.more.enumerated()), id: \.offset) { _, part in
                            UserPrompt(text: part.text, images: part.images, tint: promptTint)
                        }
                    }
                        // Sent like an iMessage: up from the composer, a little small, then a
                        // springy settle into place. Just a fade under Reduce Motion.
                        .scaleEffect(landed || reduceMotion ? 1 : 0.86, anchor: .bottomTrailing)
                        .offset(y: landed || reduceMotion ? 0 : 44)
                        .opacity(landed ? 1 : 0)
                        .onAppear {
                            guard !landed else { return }
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.66)) {
                                landed = true
                            }
                        }
                        .contextMenu { menu(changes: parts.changes.count) }
                    PromptActions(
                        turn: turn,
                        visible: hoveringPrompt && !(running && turn.number == nil),
                        canRewind: actions.canRewind,
                        copy: copy,
                        rewind: { confirmRewind = true },
                        fork: { if let n = turn.number { actions.fork?(n) } }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(.rect)
                .onHover { hoveringPrompt = $0 }
            }
            // The answer being written is a typing bubble at the turn's end, not a plain row:
            // the model's words appear as they arrive, with the frog beside them. The bubble
            // IS that row (so the handoff is a fade inside one view, not a swap of two), and
            // it settles to the plain row when the message completes; tool rows run above it.
            ForEach(flow.segments) { segment in
                SegmentRow(segment: segment, conversation: conversation, live: running, verbosity: verbosity)
                    .equatable()
                    .modifier(FadeIn(enabled: running))
                    .id(segment.id)
                    .background {
                        // The answer being written: where it starts, so a long one stops there.
                        if running, segment.id == liveAnswerID, let track {
                            Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(TranscriptView.content)).minY }) {
                                track.answer = (segment.id, $0)
                            }
                        }
                    }
            }
            if running, !parts.plan.isEmpty {
                PlanView(todos: parts.plan)
            }
            if running, let loading = modelLoading {
                ModelLoadingStatus(model: loading.model, since: loading.since)
                    .transition(.opacity)
            } else if running, let status = liveStatus {
                LiveStatus(text: status.text, since: status.since, preview: thinking)
                    .transition(.opacity)
            }
            if !parts.changes.isEmpty {
                ChangesStrip(changes: parts.changes)
                    .equatable()
            }
            if let end = turn.end {
                // An unpinned footer keeps its place and fades in on hover, so it neither
                // covers the answer nor shifts what's below.
                EndView(reason: end, usage: turn.usage, answer: answer, hovering: hovering)
                    // Set off from the answer above it (see `TurnSpace`): the turn's last
                    // line reads as a caption, not as one more paragraph.
                    .padding(.top, isFooter(end) ? space.beforeFooter : 0)
                    .opacity(pinsFooter || !isFooter(end) || hovering ? 1 : 0)
                    .allowsHitTesting(pinsFooter || hovering)

            }
        }
        .padding(.top, gap)
        .onHover(perform: hover)
        .confirmationDialog(
            "Rewind to before this turn?",
            isPresented: $confirmRewind
        ) {
            Button("Rewind", role: .destructive) {
                if let n = turn.number { actions.rewind?(n) }
            }
        } message: {
            Text("Files frog edited in this turn and later go back to how they were, and the conversation continues on a new branch from here. The current session is kept. Changes made by shell commands aren't undone.")
        }
    }

    private var prompt: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Messages queued while the last turn ran go together: a bubble each.
            VStack(alignment: .trailing, spacing: 6) {
                UserPrompt(text: turn.input, images: turn.images, tint: promptTint)
                ForEach(Array(turn.more.enumerated()), id: \.offset) { _, part in
                    UserPrompt(text: part.text, images: part.images, tint: promptTint)
                }
            }
                // Sent like an iMessage: up from the composer, a little small, then a
                // springy settle into place. Just a fade under Reduce Motion.
                .scaleEffect(landed || reduceMotion ? 1 : 0.86, anchor: .bottomTrailing)
                .offset(y: landed || reduceMotion ? 0 : 44)
                .opacity(landed ? 1 : 0)
                .onAppear {
                    guard !landed else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.66)) {
                        landed = true
                    }
                }
                .contextMenu { menu(changes: TurnParts(turn).changes.count) }
            PromptActions(
                turn: turn,
                visible: hoveringPrompt && !(running && turn.number == nil),
                canRewind: actions.canRewind,
                copy: copy,
                rewind: { confirmRewind = true },
                fork: { if let n = turn.number { actions.fork?(n) } }
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(.rect)
        .onHover { hoveringPrompt = $0 }
    }

    // The answer being written is a typing bubble at the turn's end, not a plain row: the
    // model's words appear as they arrive, with the frog beside them. The bubble IS that row
    // (so the handoff is a fade inside one view, not a swap of two), and it settles to the
    // plain row when the message completes; tool rows run above it.
    private func row(_ segment: TurnFlow.Segment) -> some View {
        SegmentRow(segment: segment, conversation: conversation, live: running, verbosity: verbosity)
            .equatable()
            .modifier(FadeIn(enabled: running))
            .background {
                // The answer being written: where it starts, so a long one stops there.
                if running, segment.id == liveAnswerID, let track {
                    Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(TranscriptView.content)).minY }) {
                        track.answer = (segment.id, $0)
                    }
                }
            }
            .padding(.top, gap)
            .onHover(perform: hover)
    }

    @ViewBuilder
    private var tail: some View {
        let parts = TurnParts(turn)
        let loading = running ? modelLoading : nil
        let status = running && loading == nil ? liveStatus : nil
        let plan = running && !parts.plan.isEmpty
        if plan || loading != nil || status != nil || !parts.changes.isEmpty || turn.end != nil {
            VStack(alignment: .leading, spacing: space.inTurn) {
                if plan {
                    PlanView(todos: parts.plan)
                }
                if let loading {
                    ModelLoadingStatus(model: loading.model, since: loading.since)
                        .transition(.opacity)
                } else if let status {
                    LiveStatus(text: status.text, since: status.since, preview: thinking)
                        .transition(.opacity)
                }
                if !parts.changes.isEmpty {
                    ChangesStrip(changes: parts.changes)
                        .equatable()
                }
                if let end = turn.end {
                    // An unpinned footer keeps its place and fades in on hover, so it neither
                    // covers the answer nor shifts what's below.
                    EndView(reason: end, usage: turn.usage, answer: answer, hovering: hovering)
                        // Set off from the answer above it (see `TurnSpace`): the turn's last
                        // line reads as a caption, not as one more paragraph.
                        .padding(.top, isFooter(end) ? space.beforeFooter : 0)
                        .opacity(pinsFooter || !isFooter(end) || hovering ? 1 : 0)
                        .allowsHitTesting(pinsFooter || hovering)
                }
            }
            .padding(.top, gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover(perform: hover)
        }
    }

    /// A finished turn's model/speed caption, as opposed to a banner for how it stopped
    /// (interrupted, an error), which always shows.
    private func isFooter(_ end: EndReason) -> Bool {
        switch end {
        case .complete, .denied: true
        default: false
        }
    }

    /// What's happening now, for the turn's last line. Nothing while the answer is being
    /// written (the text is the status), a permission card is up, or a subagent or diagram
    /// shows its own progress.
    private var liveStatus: (text: String, since: Date?)? {
        guard let last = turn.items.last else { return nil }
        if last.kind == .message, !last.done, !last.text.isEmpty { return nil }
        if let current = turn.items.last(where: { !$0.done && $0.kind != .message }) {
            if current.needsPermission { return nil }
            if case .tool(let name, _) = current.kind, name == "Task" || name == "Diagram" { return nil }
            return (ActivityWords.now(current), current.startedAt)
        }
        // Between steps: the model is working out what to do next.
        let label = conversation.progress.flatMap { p -> String? in
            guard p.label != "thinking", !p.label.isEmpty else { return nil }
            let s = p.label.prefix(1).uppercased() + p.label.dropFirst()
            return s.hasSuffix("…") ? s : s + "…"
        }
        return (label ?? "Thinking…", turn.items.compactMap(\.endedAt).max())
    }

    /// Tang accepts the first completion before its weights are resident. That request is model
    /// loading, rather than reasoning, until the server begins to stream its first response.
    private var modelLoading: (model: String, since: Date)? {
        guard turn.items.isEmpty, let progress = conversation.progress,
              progress.label.lowercased().hasPrefix("loading ") else { return nil }
        let raw = String(progress.label.dropFirst("loading ".count))
        return (Self.modelName(raw), conversation.progressSince ?? turn.startedAt ?? .now)
    }

    /// The prompt has a row: what you asked, or a message from another session.
    static func hasHead(_ turn: TurnState) -> Bool {
        !turn.input.isEmpty || !turn.more.isEmpty
    }

    private static func modelName(_ raw: String) -> String {
        let name = raw.split(separator: "/").last.map(String.init) ?? raw
        return name
            .replacingOccurrences(of: "-4bit", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    @ViewBuilder
    private func menu(changes: Int) -> some View {
        if turn.number != nil, turn.finished, actions.canRewind {
            Button("Rewind to Before This Turn…", systemImage: "arrow.uturn.backward") { confirmRewind = true }
            Button("Fork from Here", systemImage: "arrow.triangle.branch") {
                if let n = turn.number { actions.fork?(n) }
            }
            Divider()
        }
        Button("Copy", systemImage: "doc.on.doc") { copy() }
    }

    /// What frog said in this turn, for copying.
    private var answer: String {
        turn.items.filter { $0.kind == .message }.map(\.text).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copy() {
        Clipboard.copy(turn.request)
    }
}

/// One row of a turn. Rebuilt only when what it shows changed (see `ItemStamp`): a finished
/// row is left alone as rows stream in below it, so a new row costs one row, not the turn.
/// What a row reads from the conversation (a permission card, gists) still updates it.
private struct SegmentRow: View, Equatable {
    let segment: TurnFlow.Segment
    let conversation: Conversation
    let live: Bool
    let verbosity: Verbosity

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.live == b.live, a.verbosity == b.verbosity, a.conversation === b.conversation,
              a.segment.id == b.segment.id, let x = a.segment.stamp, let y = b.segment.stamp else { return false }
        return x == y
    }

    var body: some View {
        content
        #if DEBUG
            .onAppear { TranscriptProbe.mounted(probeKey, true) }
            .onDisappear { TranscriptProbe.mounted(probeKey, false) }
        #endif
    }

    #if DEBUG
    private var probeKey: String { "\(ObjectIdentifier(conversation).hashValue)-\(segment.id)" }
    #endif

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .activity(let group):
            ActivityLine(group: group, conversation: conversation, live: live, verbosity: verbosity)
        case .text(let item), .visual(let item), .notice(let item):
            ItemView(item: item, conversation: conversation,
                     typing: live && !item.done && item.kind == .message)
        }
    }
}

/// A row that arrives while the turn streams fades in where it lands: opacity only, so it
/// doesn't move the rows above it or ease the transcript's height.
private struct FadeIn: ViewModifier {
    let enabled: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard enabled, !shown else { return }
                withAnimation(.easeOut(duration: 0.18)) { shown = true }
            }
    }
}

/// How a turn's items split into work, answer, plan, and changes.
struct TurnParts {
    var work: [ItemState] = []
    var answer: [ItemState] = []
    var plan: [Todo] = []
    var changes: [FileChange] = []

    init(_ turn: TurnState) {
        // Messages after the last tool call are the answer; everything else is work. Diagrams
        // (and MCP apps and images) are part of the answer wherever they come.
        func isDiagram(_ item: ItemState) -> Bool {
            if case .tool(let name, _) = item.kind, name == "Diagram" { true } else { false }
        }
        // MCP results with their own UI (an app, or images) and Present's blocks are shown like
        // diagrams.
        // Each call to an app's tools remounts the app, so only the latest per app is shown.
        var latestApp: [String: String] = [:]
        for item in turn.items {
            if let app = item.result?.app { latestApp[app.server + app.uri] = item.id }
        }
        func isVisual(_ item: ItemState) -> Bool {
            guard let r = item.result, r.outcome == .ok else { return false }
            if r.present != nil { return true }
            if let app = r.app { return latestApp[app.server + app.uri] == item.id }
            return !(r.images ?? []).isEmpty
        }
        let lastTool = turn.items.lastIndex { item in
            if case .tool = item.kind { !isDiagram(item) && !isVisual(item) } else { false }
        }
        for (i, item) in turn.items.enumerated() {
            let isAnswer: Bool = {
                if isDiagram(item) { return item.result?.diagram != nil || !item.done }
                if isVisual(item) { return true }
                guard item.kind == .message else { return false }
                guard let lastTool else { return true }
                return i > lastTool
            }()
            if isAnswer { answer.append(item) } else { work.append(item) }

            guard let r = item.result, r.outcome == .ok else { continue }
            if r.name == "TodoWrite", let todos = r.input?["todos"]?.array {
                plan = todos.compactMap { t in
                    guard let content = t["content"]?.string else { return nil }
                    return Todo(content: content, status: t["status"]?.string ?? "pending")
                }
            }
            if let diff = r.diff {
                if let j = changes.firstIndex(where: { $0.path == diff.path }) {
                    changes[j].diffs.append(diff)
                } else {
                    changes.append(FileChange(path: diff.path, diffs: [diff]))
                }
            }
        }
    }
}

struct FileChange: Identifiable, Hashable {
    let path: String
    var diffs: [FileDiff]

    var id: String { path }
    var added: UInt32 { diffs.reduce(0) { $0 + $1.added } }
    var removed: UInt32 { diffs.reduce(0) { $0 + $1.removed } }
    var created: Bool { diffs.first?.created ?? false }
    var name: String { (path as NSString).lastPathComponent }
}

struct PlanView: View {
    let todos: [Todo]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(todo.status)
                        .frame(width: 14)
                    Text(todo.content)
                        .strikethrough(todo.status == "completed", color: .secondary)
                        .foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                        .fontWeight(todo.status == "in_progress" ? .medium : .regular)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: .rect(cornerRadius: 10))
        .animation(.smooth, value: todos)
    }

    @ViewBuilder
    private func icon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "in_progress":
            Image(systemName: "circle.dotted.circle").foregroundStyle(.tint)
                .symbolEffect(.rotate, isActive: true)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Changes

struct ChangesStrip: View, Equatable {
    let changes: [FileChange]
    @State private var open: String?

    /// A file's edits only ever append: the same files with as many edits each is the same
    /// strip, without comparing every hunk of every diff on every chunk.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.changes.count == b.changes.count
            && zip(a.changes, b.changes).allSatisfy { $0.path == $1.path && $0.diffs.count == $1.diffs.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(changes) { change in
                        Button {
                            withAnimation(.snappy) { open = open == change.path ? nil : change.path }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: change.created ? "doc.badge.plus" : "doc.text")
                                Text(change.name).fontWeight(.medium)
                                Text("+\(change.added)").foregroundStyle(.green)
                                Text("−\(change.removed)").foregroundStyle(.red)
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                open == change.path ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: .capsule
                            )
                        }
                        .buttonStyle(.plain)
                        .help(change.path)
                        .fileActions(change.path)
                    }
                }
            }
            if let path = open, let change = changes.first(where: { $0.path == path }) {
                VStack(spacing: 8) {
                    ForEach(Array(change.diffs.enumerated()), id: \.offset) { _, diff in
                        DiffView(diff: diff)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

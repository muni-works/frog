import SwiftUI

/// A turn reads like prose, in the order things happened: what you asked, then text and
/// muted lines for what frog did in between ("Read 3 files, searched for …"), then the files
/// that changed. Cards are only for what needs you or went wrong.
struct TurnActions {
    var fork: (UInt64) -> Void
    var rewind: (UInt64) -> Void
}

struct TurnView: View {
    let turn: TurnState
    let conversation: Conversation
    let actions: TurnActions
    /// Show the model/speed footer without hovering (see `TurnFooter.pinned`).
    var pinsFooter = true
    @State private var hovering = false
    /// The pointer is over what you asked (its actions show) rather than elsewhere in the turn.
    @State private var hoveringPrompt = false
    @State private var confirmRewind = false
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("density") private var density = Density.comfortable.rawValue

    private var running: Bool { !turn.finished && conversation.busy }

    var body: some View {
        let parts = TurnParts(turn)
        let flow = TurnFlow(turn.items, showThinking: showThinking)
        VStack(alignment: .leading, spacing: density == Density.compact.rawValue ? 8 : 14) {
            if !turn.input.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    UserPrompt(text: turn.input, images: turn.images)
                        .contextMenu { menu(changes: parts.changes.count) }
                    PromptActions(
                        turn: turn,
                        visible: hoveringPrompt && !(running && turn.number == nil),
                        copy: copy,
                        rewind: { confirmRewind = true },
                        fork: { if let n = turn.number { actions.fork(n) } }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(.rect)
                .onHover { hoveringPrompt = $0 }
            }
            ForEach(flow.segments) { segment in
                switch segment {
                case .activity(let group):
                    ActivityLine(group: group, conversation: conversation, live: running)
                case .text(let item), .visual(let item), .notice(let item):
                    ItemView(item: item, conversation: conversation)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if running, !parts.plan.isEmpty {
                PlanView(todos: parts.plan)
            }
            if running, let status = liveStatus {
                LiveStatus(text: status.text, since: status.since)
                    .transition(.opacity)
            }
            if !parts.changes.isEmpty {
                ChangesStrip(changes: parts.changes)
            }
            if let end = turn.end {
                // An unpinned footer keeps its place and fades in on hover, so it neither
                // covers the answer nor shifts what's below.
                EndView(reason: end, usage: turn.usage, answer: answer, hovering: hovering)
                    .opacity(pinsFooter || !isFooter(end) || hovering ? 1 : 0)
                    .allowsHitTesting(pinsFooter || hovering)
            }
        }
        .animation(.snappy(duration: 0.25), value: flow.segments.count)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .confirmationDialog(
            "Rewind to before this turn?",
            isPresented: $confirmRewind
        ) {
            Button("Rewind", role: .destructive) {
                if let n = turn.number { actions.rewind(n) }
            }
        } message: {
            Text("Files frog edited in this turn and later go back to how they were, and the conversation continues on a new branch from here. The current session is kept. Changes made by shell commands aren't undone.")
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
            guard p != "thinking", !p.isEmpty else { return nil }
            let s = p.prefix(1).uppercased() + p.dropFirst()
            return s.hasSuffix("…") ? s : s + "…"
        }
        return (label ?? "Thinking…", turn.items.compactMap(\.endedAt).max())
    }

    @ViewBuilder
    private func menu(changes: Int) -> some View {
        if turn.number != nil, turn.finished {
            Button("Rewind to Before This Turn…", systemImage: "arrow.uturn.backward") { confirmRewind = true }
            Button("Fork from Here", systemImage: "arrow.triangle.branch") {
                if let n = turn.number { actions.fork(n) }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.input, forType: .string)
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
        // MCP results with their own UI (an app, or images) are shown like diagrams.
        // Each call to an app's tools remounts the app, so only the latest per app is shown.
        var latestApp: [String: String] = [:]
        for item in turn.items {
            if let app = item.result?.app { latestApp[app.server + app.uri] = item.id }
        }
        func isVisual(_ item: ItemState) -> Bool {
            guard let r = item.result, r.outcome == .ok else { return false }
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

struct ChangesStrip: View {
    let changes: [FileChange]
    @State private var open: String?

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

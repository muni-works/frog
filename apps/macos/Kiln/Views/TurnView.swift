import SwiftUI

/// A turn reads outcome-first: what you asked, a one-line summary of the work (expandable),
/// the answer, and the files that changed. The step-by-step lives in the work group.
struct TurnActions {
    var fork: (UInt64) -> Void
    var rewind: (UInt64) -> Void
}

struct TurnView: View {
    let turn: TurnState
    let conversation: Conversation
    let actions: TurnActions
    @State private var hovering = false
    @State private var confirmRewind = false
    @AppStorage("showThinking") private var showThinking = true

    var body: some View {
        let parts = TurnParts(turn)
        VStack(alignment: .leading, spacing: 14) {
            if !turn.input.isEmpty {
                UserPrompt(text: turn.input)
                    .overlay(alignment: .bottomTrailing) {
                        if hovering, turn.finished, turn.number != nil, !conversation.busy {
                            hoverBar(changes: parts.changes.count)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .contextMenu { menu(changes: parts.changes.count) }
            }
            let steps = showThinking ? parts.work : parts.work.filter { $0.kind != .reasoning }
            if !steps.isEmpty {
                WorkGroup(turn: turn, steps: steps, plan: parts.plan, conversation: conversation)
            }
            ForEach(parts.answer) { item in
                ItemView(item: item, conversation: conversation)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !parts.changes.isEmpty {
                ChangesStrip(changes: parts.changes)
            }
            if let end = turn.end {
                EndView(reason: end, usage: turn.usage)
            }
        }
        .animation(.snappy(duration: 0.25), value: parts.answer.count)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .confirmationDialog(
            "Rewind to before this turn?",
            isPresented: $confirmRewind
        ) {
            Button("Rewind", role: .destructive) {
                if let n = turn.number { actions.rewind(n) }
            }
        } message: {
            Text("Files kiln edited in this turn and later go back to how they were, and the conversation continues on a new branch from here. The current session is kept. Changes made by shell commands aren't undone.")
        }
    }

    private func hoverBar(changes: Int) -> some View {
        HStack(spacing: 2) {
            Button("Rewind", systemImage: "arrow.uturn.backward") { confirmRewind = true }
                .help("Rewind to before this turn")
            Button("Fork", systemImage: "arrow.triangle.branch") {
                if let n = turn.number { actions.fork(n) }
            }
            .help("Branch the conversation after this turn")
            Button("Copy", systemImage: "doc.on.doc") { copy() }
                .help("Copy prompt")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .offset(y: 30)
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
        // Messages after the last tool call are the answer; everything else is work.
        let lastTool = turn.items.lastIndex { if case .tool = $0.kind { true } else { false } }
        for (i, item) in turn.items.enumerated() {
            let isAnswer: Bool = {
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

// MARK: - Work group

struct WorkGroup: View {
    let turn: TurnState
    let steps: [ItemState]
    let plan: [Todo]
    let conversation: Conversation
    @State private var expanded = false

    private var running: Bool { !turn.finished }
    private static let tail = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if running, !plan.isEmpty {
                PlanView(todos: plan)
            }
            if expanded {
                stepsList(steps)
                if !running, !plan.isEmpty {
                    PlanView(todos: plan)
                }
            } else if running {
                let hidden = max(0, steps.count - Self.tail)
                if hidden > 0 {
                    Button("\(hidden) earlier step\(hidden == 1 ? "" : "s")") {
                        withAnimation(.snappy) { expanded = true }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 26)
                }
                stepsList(Array(steps.suffix(Self.tail)))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(running || expanded ? 0.28 : 0), in: .rect(cornerRadius: 14))
        .animation(.snappy(duration: 0.25), value: expanded)
        .animation(.snappy(duration: 0.25), value: steps.count)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).frame(width: 16)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Working \(elapsed)")
                            .monospacedDigit()
                    }
                    .fontWeight(.medium)
                    if let label = conversation.progress, label != "thinking" {
                        Text(label).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Image(systemName: failures > 0 ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(failures > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text("Worked \(elapsed)").fontWeight(.medium)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.callout)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func stepsList(_ items: [ItemState]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                ItemView(item: item, conversation: conversation)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var elapsed: String {
        guard let start = turn.startedAt else { return "" }
        let secs = Int((turn.endedAt ?? .now).timeIntervalSince(start))
        return secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s"
    }

    private var failures: Int {
        steps.filter { $0.result.map { $0.outcome == .error } ?? false }.count
    }

    /// "read 3 files · ran 2 commands · 1 search · 1 failed"
    private var summary: String {
        var counts: [String: Int] = [:]
        var files = Set<String>()
        var edited = Set<String>()
        for s in steps {
            guard case .tool(let name, let arg) = s.kind else { continue }
            switch name {
            case "Read": files.insert(arg)
            case "Bash", "!": counts["command", default: 0] += 1
            case "Grep", "Glob": counts["search", default: 0] += 1
            case "Edit", "Write": if s.result?.outcome == .ok { edited.insert(arg) }
            default: break
            }
        }
        var parts: [String] = []
        if !files.isEmpty { parts.append("read \(files.count) file\(files.count == 1 ? "" : "s")") }
        if !edited.isEmpty { parts.append("edited \(edited.count) file\(edited.count == 1 ? "" : "s")") }
        if let n = counts["command"] { parts.append("ran \(n) command\(n == 1 ? "" : "s")") }
        if let n = counts["search"] { parts.append("\(n) search\(n == 1 ? "" : "es")") }
        if failures > 0 { parts.append("\(failures) failed") }
        if parts.isEmpty {
            let thoughts = steps.filter { $0.kind == .reasoning }.count
            if thoughts > 0 { parts.append("thought it through") }
        }
        return parts.joined(separator: " · ")
    }
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

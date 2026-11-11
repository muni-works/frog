import Foundation

/// A turn as it happened, in order: text, what frog did, more text, and so on. Consecutive
/// steps (thinking and tool calls) between two pieces of text are one activity group, which
/// reads as a single line ("Read 3 files, searched for “.id(”") until it's opened.
struct TurnFlow {
    enum Segment: Identifiable {
        /// A message: the model talking.
        case text(ItemState)
        /// Steps between two pieces of text.
        case activity(ActivityGroup)
        /// Results with their own UI (diagrams, MCP apps, images), shown where they came.
        case visual(ItemState)
        /// An engine notice (a warning, a summary of the context).
        case notice(ItemState)

        var id: String {
            switch self {
            case .text(let i), .visual(let i), .notice(let i): i.id
            case .activity(let g): "group-" + (g.steps.first?.id ?? "")
            }
        }
    }

    var segments: [Segment] = []

    /// `showThinking` false leaves reasoning out entirely (the setting).
    init(_ items: [ItemState], showThinking: Bool = true) {
        // Each call to an MCP app's tools remounts the app, so only the latest per app is shown.
        var latestApp: [String: String] = [:]
        for item in items {
            if let app = item.result?.app { latestApp[app.server + app.uri] = item.id }
        }
        func isVisual(_ item: ItemState) -> Bool {
            guard case .tool(let name, _) = item.kind else { return false }
            if !item.done && item.imagePreview != nil { return true }
            if name == "Diagram" { return item.result?.diagram != nil || !item.done }
            guard let r = item.result, r.outcome == .ok else { return false }
            if r.present != nil { return true }
            if let app = r.app { return latestApp[app.server + app.uri] == item.id }
            return !(r.images ?? []).isEmpty
        }

        var run: [ItemState] = []
        func flush() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            // Only a short thought, and nothing done: a model's scratch line before answering
            // (Apple Intelligence writes one every turn). Not worth a line of its own.
            if run.allSatisfy({ $0.kind == .reasoning && $0.done && ActivityGroup.isShort($0) }) { return }
            // A long thought before acting is its own line ("Thought for 12s"); a short one
            // folds into the line that follows ("Thought, then read 3 files").
            // Any thought before acting is its own quiet line ("Thought ›"), as on the web.
            if run.count > 1, let first = run.first, first.kind == .reasoning, first.done,
               run.dropFirst().contains(where: { $0.kind != .reasoning }) {
                segments.append(.activity(ActivityGroup(steps: [first])))
                segments.append(.activity(ActivityGroup(steps: Array(run.dropFirst()))))
            } else {
                segments.append(.activity(ActivityGroup(steps: run)))
            }
        }
        for item in items {
            switch item.kind {
            case .message:
                // A message that hasn't said anything yet doesn't break the group.
                guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flush()
                segments.append(.text(item))
            case .notice:
                flush()
                segments.append(.notice(item))
            case .reasoning:
                if showThinking { run.append(item) }
            case .tool:
                if isVisual(item) {
                    flush()
                    segments.append(.visual(item))
                } else {
                    run.append(item)
                }
            }
        }
        flush()
    }
}

/// What a finished item shows, cheaply comparable: the transcript rebuilds a row only when its
/// stamp changes, instead of every row on every chunk (`ItemState` isn't Equatable, so SwiftUI
/// can't tell an unchanged row from a changed one by itself).
struct ItemStamp: Equatable {
    let id: String
    let text: Int
    let output: Int
    let result: Bool
    let ok: Bool
    let needsPermission: Bool
    let preview: Bool
    let subagentItems: Int
    let subagentEnded: Date?
}

extension ItemState {
    /// Nil while the item is still running: a live row always rebuilds.
    var stamp: ItemStamp? {
        guard done else { return nil }
        return ItemStamp(id: id, text: text.utf8.count, output: output.utf8.count, result: result != nil,
                         ok: result?.outcome == .ok, needsPermission: needsPermission, preview: imagePreview != nil,
                         subagentItems: subagent?.items.count ?? 0, subagentEnded: subagent?.endedAt)
    }

    /// What a turn's tail row (plan, live status, changes, footer) reads from one item, cheaply
    /// comparable — kind and size, not the strings themselves (see `TurnView.==`).
    var itemKey: String {
        let kind: String
        switch self.kind {
        case .message: kind = "m"
        case .reasoning: kind = "r"
        case .tool(let name, _): kind = "t:" + name
        case .notice(let warning): kind = warning ? "nw" : "n"
        }
        return "\(id)|\(kind)|\(done ? "d" : "u")|\(text.utf8.count)|\(output.utf8.count)|\(result != nil ? (result?.outcome == .ok ? "ok" : "no") : "-")|\(needsPermission ? "p" : "-")"
    }
}

extension TurnFlow.Segment {
    /// Nil while any of its items is running.
    /// A step in it is waiting on a permission answer (its card shows).
    var waiting: Bool {
        if case .activity(let g) = self { return g.steps.contains(where: \.needsPermission) }
        return false
    }

    var stamp: [ItemStamp]? {
        switch self {
        case .text(let i), .visual(let i), .notice(let i): i.stamp.map { [$0] }
        case .activity(let g):
            g.steps.reduce(into: [ItemStamp]?([])) { acc, step in
                guard let s = step.stamp else { acc = nil; return }
                acc?.append(s)
            }
        }
    }
}

/// Steps between two pieces of text, and the sentence that sums them up.
struct ActivityGroup {
    var steps: [ItemState]

    /// A thought of a sentence or so (Apple Intelligence's one-liners) isn't worth its own line.
    static func isShort(_ item: ItemState) -> Bool {
        let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 200 && !t.contains("\n\n")
    }

    /// Steps that have finished: what the line sums up. Running ones are the live status.
    var done: [ItemState] { steps.filter(\.done) }

    /// The step running now, if any.
    var current: ItemState? { steps.last { !$0.done } }

    /// Steps that failed or were refused.
    var failures: Int {
        done.filter { $0.result.map { $0.outcome == .error || $0.outcome == .denied } ?? false }.count
    }

    /// The group's line, in pieces so the view can color diff counts and failures.
    var summary: [ActivityWords.Piece] { ActivityWords.summary(done) }
}

/// How frog says what it did: past tense for lines and rows, present for the live status.
enum ActivityWords {
    enum Piece: Equatable {
        case text(String)
        case diff(added: UInt32, removed: UInt32)
        case failed(Int)
    }

    /// The pieces as one string, e.g. "Edited 2 files +18 −6, ran the tests".
    static func plain(_ pieces: [Piece]) -> String {
        pieces.map { p in
            switch p {
            case .text(let s): s
            case .diff(let a, let r): "+\(a) −\(r)"
            case .failed(let n): "\(n) failed"
            }
        }.joined()
    }

    /// One sentence for a run of steps: count and verb per kind of step, naming the file when
    /// there's one. A short thought at the start becomes "Thought, then …".
    static func summary(_ steps: [ItemState]) -> [Piece] {
        let tools = steps.filter { if case .tool = $0.kind { true } else { false } }
        let thoughts = steps.filter { $0.kind == .reasoning }
        guard !tools.isEmpty else {
            guard !thoughts.isEmpty else { return [] }
            let secs = thoughts.compactMap(\.duration).reduce(0, +)
            let hasTime = thoughts.contains { $0.duration != nil }
            return [.text(hasTime ? "Thought for \(duration(secs))" : "Thought")]
        }

        // Clauses in the order their kind first came up, each a list of pieces.
        var order: [String] = []
        var byKind: [String: [ItemState]] = [:]
        for t in tools {
            guard case .tool(let name, _) = t.kind else { continue }
            let k = kind(name)
            if byKind[k] == nil { order.append(k) }
            byKind[k, default: []].append(t)
        }
        var clauses: [[Piece]] = []
        for k in order {
            if let c = clause(k, byKind[k] ?? []) { clauses.append(c) }
        }
        let failed = tools.filter { $0.result.map { $0.outcome == .error || $0.outcome == .denied } ?? false }.count
        if failed > 0 { clauses.append([.failed(failed)]) }
        if clauses.isEmpty { clauses = [[.text("Worked")]] }

        var pieces: [Piece] = []
        if steps.first?.kind == .reasoning { pieces.append(.text("Thought, then ")) }
        for (i, c) in clauses.enumerated() {
            if i > 0 { pieces.append(.text(", ")) }
            pieces += c
        }
        return capitalized(merged(pieces))
    }

    /// Which clause a tool's calls go in.
    private static func kind(_ name: String) -> String {
        switch name {
        case "Bash", "!": "run"
        case "Grep", "Glob": "search"
        case "Edit", "Write": "edit"
        case let n where n.hasPrefix("mcp__"): "mcp:" + (n.dropFirst(5).components(separatedBy: "__").first ?? "")
        default: name
        }
    }

    private static func clause(_ kind: String, _ calls: [ItemState]) -> [Piece]? {
        let args = unique(calls.map(\.arg))
        switch kind {
        case "Read":
            return [.text(args.count == 1 ? "read \(file(args[0]))" : "read \(count(args.count, "file"))")]
        case "search":
            if args.count == 1 { return [.text("searched for “\(args[0])”")] }
            if args.count == 2 { return [.text("searched for “\(args[0])” and “\(args[1])”")] }
            return [.text("searched \(args.count) times")]
        case "edit":
            let ok = calls.filter { $0.result?.outcome == .ok }
            guard !ok.isEmpty else { return nil }
            let created = unique(ok.filter { $0.result?.diff?.created == true }.map(\.arg))
            let edited = unique(ok.map(\.arg)).filter { !created.contains($0) }
            var words: [String] = []
            if !edited.isEmpty { words.append(edited.count == 1 ? "edited \(file(edited[0]))" : "edited \(count(edited.count, "file"))") }
            if !created.isEmpty { words.append(created.count == 1 ? "created \(file(created[0]))" : "created \(count(created.count, "file"))") }
            var pieces: [Piece] = [.text(words.joined(separator: ", "))]
            let diffs = ok.compactMap { $0.result?.diff }
            if !diffs.isEmpty {
                pieces.append(.text(" "))
                pieces.append(.diff(added: diffs.reduce(0) { $0 + $1.added }, removed: diffs.reduce(0) { $0 + $1.removed }))
            }
            return pieces
        case "run":
            if calls.allSatisfy({ isTest($0.arg) }) { return [.text("ran the tests")] }
            return [.text(calls.count == 1 ? "ran a command" : "ran \(count(calls.count, "command"))")]
        case "WebFetch":
            let hosts = unique(args.map(host))
            return [.text(hosts.count == 1 ? "fetched \(hosts[0])" : "fetched \(count(args.count, "page"))")]
        case "WebSearch":
            return [.text(args.count == 1 ? "searched the web for “\(args[0])”" : "searched the web \(args.count) times")]
        case "Task":
            return [.text(calls.count == 1 ? "ran an agent" : "ran \(count(calls.count, "agent"))")]
        case "TodoWrite": return [.text("updated the plan")]
        case "Image": return [.text("generated images")]
        case "Screenshot": return [.text("captured the page")]
        case "Compare": return [.text("compared the images")]
        case "Diagram": return [.text("drew a diagram")]
        case "Present": return [.text("showed results")]
        case "Ask": return [.text(calls.count == 1 ? "asked you" : "asked you \(count(calls.count, "question"))")]
        case "CodeMap": return [.text("mapped the code")]
        case "Docs": return [.text("read the docs")]
        case "Skill": return [.text(args.count == 1 && !args[0].isEmpty ? "used the \(args[0]) skill" : "used \(count(calls.count, "skill"))")]
        case "Recall": return [.text("looked through past sessions")]
        case "UseFolder":
            guard let to = calls.last(where: { $0.result?.outcome == .ok })?.arg else { return [.text("asked to use a folder")] }
            return [.text("moved to \((to as NSString).lastPathComponent)")]
        case "McpTools": return [.text("looked up tools")]
        case let k where k.hasPrefix("mcp:"):
            let server = String(k.dropFirst(4))
            return [.text(calls.count == 1 ? "used \(server)" : "used \(server) \(calls.count) times")]
        default:
            return [.text(calls.count == 1 ? "used \(ToolIcon.title(kind))" : "used \(ToolIcon.title(kind)) \(calls.count) times")]
        }
    }

    // MARK: Rows

    /// One step, past tense: "Read PaneView.swift", "Ran python3 main.py".
    static func row(_ item: ItemState) -> String {
        switch item.kind {
        case .reasoning:
            return item.duration.map { "Thought for \(duration($0))" } ?? "Thought"
        case .message, .notice:
            return item.text
        case .tool(let name, let arg):
            switch name {
            case "Read": return "Read \(file(arg))"
            case "Grep", "Glob": return "Searched for “\(arg)”"
            case "Edit": return "Edited \(file(arg))"
            case "Write": return item.result?.diff?.created == true ? "Created \(file(arg))" : "Wrote \(file(arg))"
            case "Bash", "!": return "Ran \(arg)"
            case "WebFetch": return "Fetched \(arg)"
            case "WebSearch": return "Searched the web for “\(arg)”"
            case "Task": return arg.isEmpty ? "Ran an agent" : "Agent: \(arg)"
            case "TodoWrite": return "Updated the plan"
            case "Diagram": return arg.isEmpty ? "Drew a diagram" : "Drew \(arg)"
            case "Present": return "Showed results"
            case "Ask": return "Asked you"
            case "CodeMap": return "Mapped the code"
            case "Docs": return arg.isEmpty ? "Read the docs" : "Read the docs for \(arg)"
            case "Skill": return "Used the \(arg) skill"
            case "Recall": return arg.isEmpty ? "Looked through past sessions" : "Looked through past sessions for “\(arg)”"
            case "UseFolder": return "Moved to \(arg.isEmpty ? "a folder" : arg)"
            default: return arg.isEmpty ? "Used \(ToolIcon.title(name))" : "Used \(ToolIcon.title(name)) \(arg)"
            }
        }
    }

    /// What's happening now, for the live line: "Reading Sidebar.swift…", "Running the tests…".
    static func now(_ item: ItemState) -> String {
        switch item.kind {
        case .reasoning, .message, .notice:
            return "Thinking…"
        case .tool(let name, let arg):
            switch name {
            case "Read": return "Reading \(file(arg))…"
            case "Grep", "Glob": return "Searching for “\(arg)”…"
            case "Edit": return "Editing \(file(arg))…"
            case "Write": return "Writing \(file(arg))…"
            case "Bash", "!": return isTest(arg) ? "Running the tests…" : "Running \(arg)…"
            case "WebFetch": return "Fetching \(host(arg))…"
            case "WebSearch": return "Searching the web for “\(arg)”…"
            case "Task":
                return item.subagent.map { "Agent: \($0.activity)…" } ?? "Starting an agent…"
            case "TodoWrite": return "Updating the plan…"
            case "Image": return "Generating images…"
            case "Screenshot": return "Capturing the page…"
            case "Compare": return "Comparing images…"
            case "Diagram": return "Drawing a diagram…"
            case "Present": return "Laying out results…"
            case "Ask": return "Waiting for your answer…"
            case "CodeMap": return "Mapping the code…"
            case "Docs": return "Reading the docs…"
            case "Recall": return "Looking through past sessions…"
            case "UseFolder": return "Moving to a folder…"
            default: return "Using \(ToolIcon.title(name))…"
            }
        }
    }

    // MARK: Helpers

    /// 12 → "12s", 95 → "1m 35s"; never "0s".
    static func duration(_ secs: TimeInterval) -> String {
        let s = max(1, Int(secs.rounded()))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    static func isTest(_ command: String) -> Bool {
        command.lowercased().contains("test")
    }

    private static func file(_ path: String) -> String {
        path.isEmpty ? "a file" : (path as NSString).lastPathComponent
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host() ?? url
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }

    /// Adjacent text pieces as one, so the view makes fewer `Text`s.
    private static func merged(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for p in pieces {
            if case .text(let b) = p, case .text(let a)? = out.last {
                out[out.count - 1] = .text(a + b)
            } else {
                out.append(p)
            }
        }
        return out
    }

    private static func capitalized(_ pieces: [Piece]) -> [Piece] {
        guard case .text(let s)? = pieces.first else {
            // "2 failed" leads only when nothing else happened.
            return pieces
        }
        var out = pieces
        out[0] = .text(s.prefix(1).uppercased() + s.dropFirst())
        return out
    }
}

/// Which turns show their model/speed footer without hovering: the latest finished one, one
/// whose model differs from the turn before, and one that cost money. Touch screens only: on
/// the Mac every footer is hover-only (`TranscriptView`), so nothing is pinned at rest.
enum TurnFooter {
    static func pinned(_ turns: [TurnState], cost: (TurnUsage) -> Double? = { _ in nil }) -> Set<TurnState.ID> {
        var out = Set<TurnState.ID>()
        var previous: String?
        for turn in turns {
            guard turn.finished, let usage = turn.usage, usage.modelCalls > 0 else { continue }
            let model = usage.model
            if previous != nil, model != previous { out.insert(turn.id) }
            if (cost(usage) ?? 0) > 0 { out.insert(turn.id) }
            previous = model ?? previous
        }
        if let last = turns.last(where: { $0.finished && $0.usage != nil }) { out.insert(last.id) }
        return out
    }
}

extension ItemState {
    /// How long the step took, when the engine said when it started and ended.
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// The tool call's argument, or "".
    var arg: String {
        if case .tool(_, let arg) = kind { arg } else { "" }
    }
}

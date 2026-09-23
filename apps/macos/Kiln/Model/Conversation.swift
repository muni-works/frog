import Foundation
import Observation

/// One entry in a turn: a message, reasoning, a tool call, or an engine notice.
struct ItemState: Identifiable {
    enum Kind: Equatable {
        case message
        case reasoning
        case tool(name: String, arg: String)
        case notice(warning: Bool)
    }

    let id: String
    var kind: Kind
    var text = ""
    /// Live output from a running tool.
    var output = ""
    var result: Item.ToolResult?
    var done = false
    var needsPermission = false
    /// Reported by a running MCP tool.
    var progress: ToolProgress?
    /// For a `Task` call: the subagent's own run, live.
    var subagent: SubagentRun?
}

/// A subagent's run as it streams in: its items (thinking, tool calls, the report being
/// written) and its speed.
struct SubagentRun {
    var items: [ItemState] = []
    var startedAt = Date()
    var endedAt: Date?
    var tokensPerSec: Double?
    var contextTokens: UInt64?
    var stopping = false

    var steps: Int { items.filter { if case .tool = $0.kind { true } else { false } }.count }

    /// What it's doing right now, for headers and the activity viewer.
    var activity: String {
        guard let last = items.last else { return "Starting" }
        switch last.kind {
        case .tool(let name, let arg):
            let verb = ["Read": "Reading", "Grep": "Searching", "Glob": "Finding", "CodeMap": "Mapping"][name] ?? ToolIcon.title(name)
            return last.done ? "Thinking" : (arg.isEmpty ? verb : "\(verb) \((arg as NSString).lastPathComponent)")
        case .reasoning: return "Thinking"
        case .message: return last.done ? "Reporting" : "Writing the report"
        case .notice: return last.text
        }
    }

    /// Fold one of the subagent's events in.
    mutating func apply(_ event: Event) {
        switch event {
        case .itemStarted(let id, let kind):
            upsert(id) { item in
                switch kind {
                case .message: item.kind = .message
                case .reasoning: item.kind = .reasoning
                case .toolCall(let name, let arg): item.kind = .tool(name: name, arg: arg)
                }
            }
        case .itemDelta(let id, let delta):
            upsert(id) { item in
                switch delta {
                case .text(let t), .reasoning(let t): item.text += t
                case .output(let t): item.output += t
                }
            }
        case .itemCompleted(let id, let item):
            upsert(id) { state in
                state.done = true
                switch item {
                case .message(let t): state.kind = .message; state.text = t
                case .reasoning(let t): state.kind = .reasoning; state.text = t
                case .toolCall(let r): state.kind = .tool(name: r.name, arg: r.arg); state.result = r
                }
            }
        case .status(let s):
            tokensPerSec = s.tokensPerSec
            contextTokens = s.contextTokens
        default:
            break
        }
    }

    private mutating func upsert(_ id: String, _ update: (inout ItemState) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            update(&items[i])
        } else {
            var item = ItemState(id: id, kind: .message)
            update(&item)
            items.append(item)
        }
    }
}

struct TurnState: Identifiable {
    let id = UUID()
    /// Assigned by the engine; nil until `turn_started` arrives for a locally echoed prompt.
    var number: UInt64?
    var input: String
    var items: [ItemState] = []
    var end: EndReason?
    var usage: TurnUsage?
    var startedAt: Date?
    var endedAt: Date?

    var finished: Bool { end != nil }
}

/// A running session: owns one `kiln --serve` process and folds its events into turns.
@MainActor
@Observable
final class Conversation {
    let folder: URL
    private(set) var sessionID: String?
    private(set) var status: Status?
    private(set) var turns: [TurnState] = []
    private(set) var busy = true
    private(set) var progress: String?
    private(set) var permission: PermissionRequest?
    /// An MCP server waiting on the user.
    private(set) var elicitation: Elicitation?
    @ObservationIgnored private var appCalls: [String: (JSONValue?, String?) -> Void] = [:]
    private(set) var failure: String?
    private(set) var replaying = false
    private(set) var title: String?
    /// A short-lived status line (info notices), shown above the composer.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Messages sent while a turn was running; they go out in order as the engine frees up.
    private(set) var queue: [String] = []

    @ObservationIgnored private var engine: EngineProcess?
    @ObservationIgnored private let replayOnStart: Bool
    @ObservationIgnored private var sawFirstIdle = false
    @ObservationIgnored private var stopping = false
    /// A notice to show once the transcript has loaded.
    @ObservationIgnored private var pendingFlash: (String, Bool)?
    /// Called when the session id changes or a turn ends, so the sidebar can refresh.
    @ObservationIgnored var onSessionChange: (() -> Void)?

    /// `arguments` are extra CLI flags, e.g. `["-r", id]` or `["--fork", "id@3"]`.
    init(folder: URL, arguments: [String], model: String?) {
        self.folder = folder
        replayOnStart = arguments.contains("-r") || arguments.contains("--fork")
        guard let binary = Kiln.binary else {
            failure = KilnError.missingBinary.localizedDescription
            busy = false
            return
        }
        var args = arguments
        if let model { args += ["-m", model] }
        let engine = EngineProcess(binary: binary, cwd: folder, arguments: args)
        engine.onEvent = { [weak self] env in self?.handle(env) }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            failure = "Couldn't start kiln: \(error.localizedDescription)"
            busy = false
        }
    }

    /// An engine-less conversation that only renders events fed to `ingest` (previews, snapshots).
    init(preview folder: URL) {
        self.folder = folder
        replayOnStart = false
        busy = false
    }

    /// Apply an event as if the engine had sent it.
    func ingest(_ env: Envelope) {
        handle(env)
    }

    // MARK: - Actions

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if busy {
            queue.append(text)
            return
        }
        if text.hasPrefix("!") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            turns.append(TurnState(number: nil, input: text, end: .complete))
            busy = true
            engine?.send(.shell(command))
            return
        }
        turns.append(TurnState(number: nil, input: text))
        busy = true
        engine?.send(.submit(text))
    }

    func unqueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
    }

    func interrupt() {
        engine?.send(.interrupt)
    }

    func answer(_ decision: Decision) {
        guard let p = permission else { return }
        engine?.send(.permission(id: p.id, decision: decision))
        permission = nil
        Notifier.shared.resolved(p.id)
    }

    /// Answer the pending MCP elicitation.
    func elicit(_ action: String, content: JSONValue? = nil) {
        guard let e = elicitation else { return }
        engine?.send(.elicit(id: e.id, action: action, content: content))
        elicitation = nil
    }

    /// An MCP App calling a tool on its server; `reply` gets the `CallToolResult` or an error.
    func callAppTool(server: String, tool: String, arguments: JSONValue, reply: @escaping (JSONValue?, String?) -> Void) {
        guard let engine else { return reply(nil, "the engine isn't running") }
        let id = UUID().uuidString
        appCalls[id] = reply
        engine.send(.appCall(id: id, server: server, tool: tool, arguments: arguments))
    }

    /// Stop one subagent; the turn goes on with what it found so far.
    func stopSubagent(_ item: String) {
        engine?.send(.stopSubagent(id: item))
        upsert(item) { $0.subagent?.stopping = true }
    }

    func setMode(_ mode: Mode) {
        engine?.send(.setMode(mode))
        status?.mode = mode
    }

    func setModel(_ spec: String) {
        engine?.send(.setModel(spec))
    }

    func compact() {
        busy = true
        engine?.send(.compact(focus: nil))
    }

    func stop() {
        stopping = true
        engine?.stop()
    }

    // MARK: - Events

    private func handle(_ env: Envelope?) {
        guard let env else {
            if !stopping {
                let tail = engine?.stderr.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
                let how = engine?.exitDescription ?? "unknown"
                failure = tail.isEmpty ? "The kiln engine exited (\(how))." : tail
            }
            busy = false
            progress = nil
            return
        }
        if sessionID != env.session {
            sessionID = env.session
            onSessionChange?()
        }
        switch env.event {
        case .turnStarted(let n, let input):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
                turns[i].startedAt = at
            } else {
                turns.append(TurnState(number: n, input: input, startedAt: at))
            }
            busy = true
        case .turnEnded(let n, let reason, let usage):
            if let i = turns.lastIndex(where: { $0.number == n }) {
                turns[i].end = reason
                turns[i].usage = usage
                turns[i].endedAt = Date(timeIntervalSince1970: Double(env.created) / 1000)
                if !replaying {
                    Notifier.shared.turnFinished(project: folder.lastPathComponent, text: Self.summary(turns[i]))
                    if title == nil, case .complete = reason { nameSession(from: turns[i]) }
                }
            }
            progress = nil
            onSessionChange?()
        case .itemStarted(let id, let kind):
            upsert(id) { $0.kind = Self.kind(kind) }
        case .itemDelta(let id, let delta):
            upsert(id) { item in
                switch delta {
                case .text(let t), .reasoning(let t): item.text += t
                case .output(let t): item.output += t
                }
            }
            progress = nil
        case .itemCompleted(let id, let item):
            upsert(id) { state in
                state.done = true
                state.needsPermission = false
                switch item {
                case .message(let t):
                    state.kind = .message
                    state.text = t
                case .reasoning(let t):
                    state.kind = .reasoning
                    state.text = t
                case .toolCall(let r):
                    state.kind = .tool(name: r.name, arg: r.arg)
                    state.result = r
                    if state.subagent?.endedAt == nil { state.subagent?.endedAt = Date() }
                }
            }
        case .permissionRequest(let req):
            permission = req
            if !replaying {
                Notifier.shared.needsPermission(project: folder.lastPathComponent, request: req) { [weak self] d in
                    self?.answer(d)
                }
            }
            upsert(req.item) { $0.needsPermission = true }
            progress = nil
        case .permissionResolved:
            permission = nil
        case .elicitation(let e):
            elicitation = e
            progress = nil
        case .elicitationDone(let id):
            if elicitation?.id == id { elicitation = nil }
        case .toolProgress(let id, let p):
            upsert(id) { $0.progress = p }
        case .subagent(let item, let inner):
            upsert(item) { state in
                if state.subagent == nil { state.subagent = SubagentRun() }
                state.subagent?.apply(inner)
            }
            progress = nil
        case .appResult(let id, let result, let error):
            appCalls.removeValue(forKey: id)?(result, error)
        case .progress(let label):
            progress = label
        case .notice(let level, let message):
            // Warnings belong in the transcript; info is transient.
            if level == "warn" { note(message, warning: true) } else { show(message) }
        case .error(let e):
            note(e.description, warning: true)
        case .compacted(let before, let after):
            note("Summarized the conversation to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .contextPruned(let n, let before, let after):
            note("Trimmed \(n) old tool result\(n == 1 ? "" : "s") to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .status(let s):
            status = s
        case .synced:
            replaying = false
            if let (text, warning) = pendingFlash {
                note(text, warning: warning)
                pendingFlash = nil
            }
        case .idle:
            if !sawFirstIdle {
                sawFirstIdle = true
                if replayOnStart {
                    replaying = true
                    engine?.send(.subscribe(after: 0))
                    return
                }
            }
            busy = false
            progress = nil
            permission = nil
            elicitation = nil
            if !queue.isEmpty {
                submit(queue.removeFirst())
            }
        case .titled(let t):
            title = t
            onSessionChange?()
        case .modelChanged, .modeChanged, .unknown:
            break
        }
    }

    /// One line for a notification: the start of the answer, or how the turn ended.
    private static func summary(_ turn: TurnState) -> String {
        switch turn.end {
        case .cancelled: return "Interrupted"
        case .error(let e): return e.description
        case .looping: return "Stopped: the model kept repeating the same tool call"
        case .stepLimit: return "Stopped at the step limit"
        default:
            let answer = turn.items.last { $0.kind == .message }?.text ?? ""
            let line = answer.split(separator: "\n").first.map(String.init) ?? "Done"
            return line.count > 140 ? String(line.prefix(140)) + "…" : line
        }
    }

    private static func kind(_ k: ItemKind) -> ItemState.Kind {
        switch k {
        case .message: .message
        case .reasoning: .reasoning
        case .toolCall(let name, let arg): .tool(name: name, arg: arg)
        }
    }

    /// Update the item with this id, creating it in the current turn if needed.
    private func upsert(_ id: String, _ update: (inout ItemState) -> Void) {
        for t in turns.indices.reversed() {
            if let i = turns[t].items.firstIndex(where: { $0.id == id }) {
                update(&turns[t].items[i])
                return
            }
        }
        if turns.isEmpty {
            turns.append(TurnState(number: nil, input: ""))
        }
        var item = ItemState(id: id, kind: .message)
        update(&item)
        turns[turns.count - 1].items.append(item)
    }

    private func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Name the session with the on-device model after its first completed turn.
    private func nameSession(from turn: TurnState) {
        let answer = turn.items.last { $0.kind == .message }?.text ?? ""
        let request = turn.input
        Task { [weak self] in
            guard let t = await Titler.title(for: request, answer: answer) else { return }
            self?.engine?.send(.setTitle(t))
        }
    }

    /// Show a one-off notice in the transcript (e.g. after a rewind).
    func flash(_ text: String, warning: Bool = false) {
        pendingFlash = (text, warning)
        if !turns.isEmpty { note(text, warning: warning); pendingFlash = nil }
    }

    private func note(_ text: String, warning: Bool) {
        let item = ItemState(id: UUID().uuidString, kind: .notice(warning: warning), text: text, done: true)
        if turns.isEmpty {
            turns.append(TurnState(number: nil, input: "", end: .complete))
        }
        turns[turns.count - 1].items.append(item)
    }
}

extension UInt64 {
    /// 12345 → "12.3k"
    var tokens: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}

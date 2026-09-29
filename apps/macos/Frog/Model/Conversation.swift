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
    /// Why auto mode let this call run without asking.
    var autoReason: String?
    /// When the engine started and finished it, for "Thought for 2s" and the live line.
    var startedAt: Date?
    var endedAt: Date?
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
    /// Images attached to the message.
    var images: [ToolImage] = []
    var items: [ItemState] = []
    var end: EndReason?
    var usage: TurnUsage?
    var startedAt: Date?
    var endedAt: Date?

    var finished: Bool { end != nil }
}

/// A running session: owns one `frog --serve` process and folds its events into turns.
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
    /// Files dropped anywhere on the conversation, for the composer to attach or mention.
    var dropped: [URL] = []
    @ObservationIgnored private var appCalls: [String: (JSONValue?, String?) -> Void] = [:]
    private(set) var failure: String?
    /// A reopened session's history is on its way (until the engine's `synced`).
    private(set) var replaying = false
    /// When this conversation was opened: only what happens after makes a sound, posts a
    /// notification or counts in the stats. Nil for previews, which never do.
    @ObservationIgnored private var openedLive: Date?

    /// Whether an event (by its timestamp) is news: live, not history coming back.
    private func isNews(_ env: Envelope) -> Bool {
        guard !replaying, let opened = openedLive else { return false }
        return Date(timeIntervalSince1970: Double(env.created) / 1000) >= opened.addingTimeInterval(-2)
    }
    /// When this conversation was opened, so a slow load can say so and a quick one doesn't.
    @ObservationIgnored let opened = Date.now
    /// Events that arrived while replaying, folded in together once the history is all here.
    @ObservationIgnored private var held: [Envelope] = []
    private(set) var title: String?
    /// Where the agent moved this conversation (`UseFolder`), if not the folder it runs in.
    /// The pane reopens it there once the turn is over (see `Panes.move`).
    private(set) var movedTo: URL?
    /// A short-lived status line (info notices), shown above the composer.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Messages sent while a turn was running; they go out in order as the engine frees up.
    private(set) var queue: [Queued] = []

    /// A message sent while a turn was running.
    struct Queued {
        var text: String
        var images: [ToolImage] = []
    }

    @ObservationIgnored private var engine: EngineProcess?
    @ObservationIgnored private let replayOnStart: Bool
    @ObservationIgnored private var sawFirstIdle = false
    @ObservationIgnored private var stopping = false
    /// A memory command (`/remember` …) is waiting for its answer, which arrives as a notice.
    @ObservationIgnored private var awaitingCommand = false
    /// A notice to show once the transcript has loaded.
    @ObservationIgnored private var pendingFlash: (String, Bool)?
    /// Called when the session id changes or a turn ends, so the sidebar can refresh.
    @ObservationIgnored var onSessionChange: (() -> Void)?
    /// The engine exited on its own (not stopped).
    @ObservationIgnored var onExit: (() -> Void)?

    /// `arguments` are extra CLI flags, e.g. `["-r", id]` or `["--fork", "id@3"]`.
    init(folder: URL, arguments: [String], model: String?) {
        self.folder = folder
        openedLive = Date()
        replayOnStart = arguments.contains("-r") || arguments.contains("--fork")
        // A reopened session is known before the engine says so: the sidebar selects it now.
        if let i = arguments.firstIndex(of: "-r"), arguments.indices.contains(i + 1) {
            sessionID = arguments[i + 1]
        }
        guard let binary = Frog.binary else {
            failure = FrogError.missingBinary.localizedDescription
            busy = false
            return
        }
        var args = arguments
        if let model { args += ["-m", model] }
        // Always measured (a sensor read ten times a second), so "Show energy use" shows every
        // turn's figure the moment it's on, earlier turns included.
        args.append("--energy")
        let engine = EngineProcess(binary: binary, cwd: folder, arguments: args)
        engine.onEvent = { [weak self] env in self?.handle(env) }
        do {
            try engine.start()
            self.engine = engine
            if replayOnStart {
                // Ask for the history straight away: the engine answers while it's still starting
                // up (connecting MCP servers, loading the model). Nothing is running, so it isn't
                // shown busy meanwhile; anything sent waits for the transcript (see `submit`).
                replaying = true
                busy = false
                engine.send(.subscribe(after: 0))
            }
        } catch {
            failure = "Couldn't start frog: \(error.localizedDescription)"
            busy = false
        }
    }

    /// An engine-less conversation that only renders events fed to `ingest` (previews, snapshots).
    /// `reopened`: as if resuming a session, whose history is fed in up to a `synced`.
    init(preview folder: URL, reopened: Bool = false) {
        self.folder = folder
        replayOnStart = reopened
        replaying = reopened
        busy = false
    }

    /// Apply an event as if the engine had sent it.
    func ingest(_ env: Envelope) {
        handle(env)
    }

    // MARK: - Actions

    func submit(_ text: String, images: [ToolImage] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if busy || replaying {
            queue.append(Queued(text: text, images: images))
            return
        }
        if text.hasPrefix("!") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            turns.append(TurnState(number: nil, input: text, end: .complete))
            busy = true
            engine?.send(.shell(command))
            return
        }
        if Self.isMemoryCommand(text) {
            // The engine answers these itself: no turn, just a notice.
            turns.append(TurnState(number: nil, input: text, end: .complete))
            busy = true
            awaitingCommand = true
            engine?.send(.submit(text, images: []))
            return
        }
        turns.append(TurnState(number: nil, input: text, images: images))
        busy = true
        engine?.send(.submit(text, images: images))
    }

    private static func isMemoryCommand(_ text: String) -> Bool {
        let name = text.split(whereSeparator: \.isWhitespace).first ?? ""
        return ["/remember", "/forget", "/memory"].contains(String(name))
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

    /// Name the session (the engine records it).
    func rename(_ title: String) {
        engine?.send(.setTitle(title))
        self.title = title
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

    /// Returns once a reopened session's history is in, or after `limit` if that's slow.
    func loaded(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while replaying, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Events

    /// A reopened session's history arrives as a burst of events. Held until it's all here and
    /// then folded in at once, it shows up whole, scrolled to the end, instead of building up
    /// turn by turn with the empty page and a spinner before it.
    private func handle(_ env: Envelope?) {
        guard replaying else { return apply(env) }
        if let env, !env.event.isSynced {
            held.append(env)
            return
        }
        let events = held
        held = []
        Motion.cut {
            events.forEach(apply)
            // Exited before the history came: show what did, then why.
            if env == nil { replaying = false }
            apply(env)
        }
    }

    private func apply(_ env: Envelope?) {
        guard let env else {
            if !stopping {
                let tail = engine?.stderr.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
                let how = engine?.exitDescription ?? "unknown"
                failure = tail.isEmpty ? "The frog engine exited (\(how))." : tail
                onExit?()
            }
            busy = false
            progress = nil
            return
        }
        if sessionID != env.session {
            sessionID = env.session
            onSessionChange?()
        }
        defer { reportLive() }
        switch env.event {
        case .turnStarted(let n, let input, let images):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
                turns[i].startedAt = at
            } else {
                turns.append(TurnState(number: n, input: input, images: images, startedAt: at))
            }
            // A replayed turn ran long ago.
            if !replaying { busy = true }
        case .turnEnded(let n, let reason, let usage):
            if let i = turns.lastIndex(where: { $0.number == n }) {
                turns[i].end = reason
                turns[i].usage = usage
                turns[i].endedAt = Date(timeIntervalSince1970: Double(env.created) / 1000)
                if isNews(env) {
                    if let id = sessionID { Library.shared.turnEnded(id) }
                    ModelStats.shared.record(usage, model: status?.model)
                    Notifier.shared.turnFinished(project: folder.lastPathComponent, text: Self.summary(turns[i]))
                    if case .complete = reason { FrogSounds.shared.play(.ribbit) }
                    if title == nil, case .complete = reason { nameSession(from: turns[i]) }
                }
            }
            progress = nil
            // Replayed turns are old news; the sidebar hears once, when the history is in.
            if !replaying { onSessionChange?() }
        case .itemStarted(let id, let kind):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            upsert(id) { item in
                item.kind = Self.kind(kind)
                if item.startedAt == nil { item.startedAt = at }
            }
        case .itemDelta(let id, let delta):
            upsert(id) { item in
                switch delta {
                case .text(let t), .reasoning(let t): item.text += t
                case .output(let t): item.output += t
                }
            }
            progress = nil
        case .itemCompleted(let id, let item):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            upsert(id) { state in
                state.done = true
                state.endedAt = at
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
            if isNews(env) {
                FrogSounds.shared.play(.drip)
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
        case .autoApproved(let item, let reason):
            upsert(item) { $0.autoReason = reason }
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
            // Warnings and command answers belong in the transcript; other info is transient.
            if awaitingCommand {
                awaitingCommand = false
                note(message, warning: level == "warn")
            } else if level == "warn" { note(message, warning: true) } else { show(message) }
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
            onSessionChange?()
            // Sent while the history loaded: it goes now (the engine takes it once started).
            if !busy, !queue.isEmpty {
                let next = queue.removeFirst()
                submit(next.text, images: next.images)
            }
        case .idle:
            if !sawFirstIdle {
                sawFirstIdle = true
                // A reopened conversation's engine finished starting up with a message already
                // waiting for it: that turn is next, so it stays busy.
                if replayOnStart, busy { return }
            }
            busy = false
            awaitingCommand = false
            progress = nil
            permission = nil
            elicitation = nil
            // While the history loads, what's queued waits for it (see `.synced`).
            if !replaying, !queue.isEmpty {
                let next = queue.removeFirst()
                submit(next.text, images: next.images)
            }
        case .titled(let t):
            title = t
            onSessionChange?()
        case .folderChanged(let cwd):
            let url = URL(fileURLWithPath: cwd)
            let here = folder.resolvingSymlinksInPath().standardizedFileURL.path
            movedTo = url.resolvingSymlinksInPath().standardizedFileURL.path == here ? nil : url
        case .modelChanged, .modeChanged, .unknown:
            break
        }
    }

    /// Tell the sidebar whether this conversation is running or waiting on the user.
    private func reportLive() {
        guard let id = sessionID, !replaying else { return }
        let running = turns.last.map { !$0.finished } ?? false
        Library.shared.report(id, conversation: self, running: running && busy, waiting: permission != nil || elicitation != nil)
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
        // Before anything's been said there's no turn to attach it to: a status line, not an
        // empty "Worked" group.
        guard !turns.isEmpty else { return show(text) }
        let item = ItemState(id: UUID().uuidString, kind: .notice(warning: warning), text: text, done: true)
        turns[turns.count - 1].items.append(item)
    }
}

extension UInt64 {
    /// 12345 → "12.3k"
    var tokens: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}

private extension Event {
    var isSynced: Bool {
        if case .synced = self { true } else { false }
    }
}

import Foundation

/// Sessions talking to sessions: carries out the model's `ListSessions`, `SendMessage` and
/// `StartSession` (an engine's `session_request`), delivers messages to the target's engine
/// (starting it with `-r` if it's closed; the engine queues them behind any running turn), sends
/// idle notices, and keeps a runaway pair of agents from messaging each other forever.
///
/// The parts that touch the app (which sessions exist, reaching an engine, starting one) are
/// closures, so routing and limits are testable without engines.
@MainActor
final class SessionBroker {
    static let shared = SessionBroker()

    /// A session as `ListSessions` shows it.
    struct Entry: Equatable {
        var id: String
        var name: String
        /// "running", "waiting" (on the user) or "idle".
        var state: String
        var cwd: String?
        var model: String?
        var modified: Int64 = 0
    }

    /// Everything `SessionStatus` reports about one session, in one structured answer.
    /// The state is the single truth the sidebar and picker use too: idle only when no turn
    /// is running AND nothing is queued (bug 2d: replayed history used to read as idle).
    struct StatusInfo: Equatable {
        var engineAlive = false
        /// A turn is open right now (turn number in `turn`).
        var turnRunning = false
        var turn: Int?
        var turnSeconds: Int?
        /// Waiting on the user: a permission, a question, an elicitation.
        var waiting = false
        var lastEnd: String?
        var model: String?
        var mode: String?
        /// Model calls across the session's turns so far.
        var modelCalls = 0
        var pendingApprovals = 0
        var pendingSummary: String?
        /// Inbound session messages sitting in the engine's inbox, waiting for the boundary.
        var queuedMessages = 0
        var cwd: String?
        var branch: String?
        var ahead: Int?
        var dirty: Int?

        /// "running", "waiting", "idle", or "dead" (no live engine). A queued message keeps
        /// a session running, whatever the last live report said.
        var state: String {
            if !engineAlive { return "dead" }
            if waiting { return "waiting" }
            if turnRunning || queuedMessages > 0 { return "running" }
            return "idle"
        }

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "engine_alive": .bool(engineAlive),
                "state": .string(state),
                "model_calls": .number(Double(modelCalls)),
                "pending_approvals": .number(Double(pendingApprovals)),
                "queued_messages": .number(Double(queuedMessages)),
            ]
            if let t = turn { o["turn"] = .number(Double(t)) }
            if let s = turnSeconds { o["turn_seconds"] = .number(Double(s)) }
            if let e = lastEnd { o["last_ended"] = .string(e) }
            if let m = model { o["model"] = .string(m) }
            if let m = mode { o["mode"] = .string(m) }
            if let s = pendingSummary { o["pending"] = .string(s) }
            if let c = cwd { o["cwd"] = .string(c) }
            if let b = branch { o["branch"] = .string(b) }
            if let a = ahead { o["ahead"] = .number(Double(a)) }
            if let d = dirty { o["dirty"] = .number(Double(d)) }
            return .object(o)
        }
    }

    /// What `StartSession` asked for.
    struct StartRequest: Equatable {
        var title: String
        var prompt: String
        var cwd: String?
        var model: String?
        var worktree: Bool
    }

    struct Started: Equatable {
        var id: String
        var name: String
        var cwd: String
        var branch: String?
        /// The ref the worktree started from (`origin/main`, say), for the tool result.
        var base: String?
    }

    /// Messages a session may send (or sessions it may start) without the user doing anything.
    static let rateLimit = 30
    static let rateWindow: TimeInterval = 10 * 60

    var directory: () -> [Entry] = { [] }
    /// Like `directory`, but including archived sessions (to resolve one for unarchiving).
    var directoryIncludingArchived: () -> [Entry] = { [] }
    /// Hide (or show) a session in the sidebar, exactly like the sidebar's own archive.
    var archiver: (_ id: String, _ on: Bool) -> Void = { _, _ in }
    /// Deliver an op to session `id`, starting its engine if needed. False if it can't be reached.
    var reach: (_ id: String, _ from: String, _ fromName: String, _ message: String) -> Bool = { _, _, _, _ in false }
    var starter: (_ request: StartRequest, _ parent: Conversation?) async throws -> Started = { _, _ in
        throw BrokerError("starting sessions isn't available")
    }
    /// A sender hit the rate limit (the app shows a notice in its transcript).
    var onLimit: (_ id: String) -> Void = { _ in }
    var now: () -> Date = Date.init
    /// The input of the turn session `id` is running, if known: an idle watch arms only once
    /// the target runs the sender's message, not the turn it was already busy with.
    var currentInput: (_ id: String) -> String? = { _ in nil }
    /// Whether session `id` is really mid-turn or has messages waiting (replayed history
    /// reports otherwise, and a notice about a session that's working would be false).
    var targetBusy: (_ id: String) -> Bool = { _ in false }
    /// What session `id` said and how its last turn ended, for the report a watcher gets when
    /// it goes idle (the hand-back from a session it started or messaged).
    var lastReport: (_ id: String) -> String? = { _ in nil }
    /// Inbound session messages waiting in a target engine's inbox, by session id. Counted
    /// here because the engine holds them; bumped on send, cleared when the target runs
    /// them (its turn starts) or is restarted dead.
    private var inbound: [String: Int] = [:]

    /// Sends since the user last did something, per sending session.
    private var sent: [String: [Date]] = [:]
    /// Senders waiting to hear that a target went idle. `armed` once the target has been seen
    /// running, so the idle it's in when the message lands doesn't count.
    /// `anyTurn`: arm on the target's next turn, whatever it runs (a session started for work,
    /// whose first turn is its prompt, not a message from the sender).
    private struct Watch { var sender: String; var armed: Bool; var anyTurn = false }
    private var watches: [String: [Watch]] = [:]
    /// Engines the broker started or kept running with no pane showing them.
    private var background: [String: Conversation] = [:]
    /// A started session's first prompt, kept (on disk) until its first turn makes a model
    /// call, so a turn 1 that dies at birth (cancelled, or its engine gone before the first
    /// call) is replayed rather than lost.
    struct Birth: Codable, Equatable {
        var prompt: String
        var attempts = 0
    }
    private(set) var births: [String: Birth] = [:]
    /// Replays allowed before giving up on a session that keeps dying at birth.
    static let birthRetries = 3
    /// Where births are kept across app restarts (nil: memory only, as in tests).
    var birthsURL: URL?
    /// Whether session `id`'s first turn has made a model call.
    var firstTurnRan: (_ id: String) -> Bool = { _ in true }
    /// Run session `id`'s first prompt again (restarting its engine if it's gone).
    var replayPrompt: (_ id: String, _ prompt: String) -> Bool = { _, _ in false }

    /// Remember a started session's first prompt until its first turn has really run.
    func recordBirth(_ id: String, prompt: String) {
        births[id] = Birth(prompt: prompt)
        saveBirths()
    }

    func loadBirths() {
        guard let url = birthsURL, let data = try? Data(contentsOf: url),
              let b = try? JSONDecoder().decode([String: Birth].self, from: data) else { return }
        births = b
    }

    private func saveBirths() {
        guard let url = birthsURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if births.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? JSONEncoder().encode(births).write(to: url, options: .atomic)
    }

    /// Whether a session's log shows a turn that made a model call (for births left over
    /// from a previous run of the app, whose conversations aren't open).
    nonisolated static func logShowsAModelCall(_ id: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/frog/sessions/\(id).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            line.contains("\"turn_ended\"") && !line.contains("\"model_calls\":0")
        }
    }
    /// Background engines seen running: stopped when they go idle.
    private var armedBackground: Set<String> = []

    struct BrokerError: LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Requests

    /// An engine's `session_request`: answer it on `c`.
    func handle(_ r: SessionRequest, from c: Conversation) {
        let sender = c.sessionID ?? ""
        let input = r.input
        switch r.tool {
        case "ListSessions":
            c.replySession(r.id, result: Self.json(list(excluding: sender)))
        case "SendMessage":
            let result = send(
                from: sender, name: name(of: c),
                to: input["to"]?.string ?? "", message: input["message"]?.string ?? "",
                notifyWhenIdle: input["notify_when_idle"]?.bool ?? false)
            switch result {
            case .success(let e):
                let how = e.state == "running" ? "queued (target busy)" : "delivered (turn started)"
                c.replySession(r.id, result: .string("Sent to \(e.name) (\(e.id)); \(how). It reads the message at its next turn boundary; its reply, if any, arrives as a <session-message>."))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "StartSession":
            if let e = charge(sender) { return c.replySession(r.id, error: e.message) }
            let req = StartRequest(
                title: input["title"]?.string ?? "", prompt: input["prompt"]?.string ?? "",
                cwd: input["cwd"]?.string, model: input["model"]?.string,
                worktree: input["worktree"]?.bool ?? false)
            Task { [weak c] in
                do {
                    let s = try await starter(req, c)
                    // A session started for work reports back when it's done, unless asked not to.
                    if input["report"]?.bool ?? true { self.watchStarted(s.id, reportTo: sender) }
                    var out: [String: JSONValue] = ["id": .string(s.id), "name": .string(s.name), "cwd": .string(s.cwd)]
                    if let b = s.branch { out["branch"] = .string(b) }
                    if let b = s.base { out["base"] = .string(b) }
                    c?.replySession(r.id, result: .object(out))
                } catch {
                    c?.replySession(r.id, error: error.localizedDescription)
                }
            }
        case "ArchiveSession", "UnarchiveSession":
            // Exactly the sidebar's archive (Library.setArchived): hides from lists, never
            // deletes the log. The archived set lives in the app's defaults, so resolving a
            // name only sees unarchived sessions — resolve against everything to unarchive.
            let key = input["id"]?.string ?? ""
            let on = r.tool == "ArchiveSession"
            switch on ? resolve(key) : resolve(key, includeArchived: true) {
            case .success(let e):
                guard e.id != sender else { return c.replySession(r.id, error: "That's this session.") }
                archive(e.id, on)
                c.replySession(r.id, result: .string(
                    "\(on ? "Archived" : "Unarchived") \(e.name) (\(e.id)).\(on ? " Its log is kept; UnarchiveSession brings it back." : " It's back in the sidebar.")"))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "SessionStatus":
            let key = input["id"]?.string ?? ""
            let target: Result<Entry, BrokerError>
            if key.isEmpty || key == sender {
                // This session: answer from what it knows about itself.
                c.replySession(r.id, result: selfStatus(of: c).map(\.json) ?? .null)
                return
            }
            target = resolve(key)
            switch target {
            case .success(let e):
                Task { [weak c] in
                    guard var info = await Self.readStatus(e.id, broker: self) else {
                        c?.replySession(r.id, error: "Couldn't read \(e.name) (\(e.id)).")
                        return
                    }
                    info.queuedMessages = self.inbound[e.id] ?? 0
                    c?.replySession(r.id, result: info.json)
                }
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "ReadSession":
            switch resolve(input["id"]?.string ?? "") {
            case .success(let e):
                let n = input["last_n"]?.int ?? 20
                let kinds = (input["kinds"]?.array ?? []).compactMap(\.string)
                Task { [weak c] in
                    let text = await Self.readTranscript(e.id, lastN: max(1, min(n, 200)), kinds: kinds, broker: self)
                    c?.replySession(r.id, result: .string(text))
                }
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "StopSession":
            // The explicit stop — the only interrupt now that SendMessage only queues. Sent
            // straight to the engine (Op.interrupt applies immediately, not at the boundary),
            // never starting one that's gone: a dead engine has nothing running.
            switch resolve(input["id"]?.string ?? "") {
            case .success(let e):
                guard e.id != sender else { return c.replySession(r.id, error: "That's this session: use your own stop.") }
                guard let target = tracked(e.id) else {
                    c.replySession(r.id, result: .string("\(e.name) (\(e.id)) has no live engine; nothing to stop."))
                    return
                }
                guard target.busy || e.state == "running" || e.state == "waiting" else {
                    c.replySession(r.id, result: .string("\(e.name) (\(e.id)) isn't running; nothing to stop."))
                    return
                }
                target.interrupt()
                c.replySession(r.id, result: .string("Stopping \(e.name) (\(e.id)): its turn ends cancelled and it goes idle."))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        default:
            c.replySession(r.id, error: "unknown session tool \(r.tool)")
        }
    }

    /// This session's own status (SessionStatus on itself): the conversation knows.
    private func selfStatus(of c: Conversation) -> StatusInfo? {
        var info = StatusInfo()
        info.engineAlive = c.isLive
        info.turnRunning = c.busy || c.turns.last.map { !$0.finished } == true
        info.turn = c.turns.last?.number.map(Int.init)
        info.turnSeconds = c.turns.last?.startedAt.map { Int(Date().timeIntervalSince($0)) }
        info.waiting = c.permission != nil || c.elicitation != nil || c.question != nil
        info.lastEnd = c.turns.last?.end.map { String(describing: $0) }
        info.model = c.status?.model
        info.mode = c.status?.mode.rawValue
        info.modelCalls = c.turns.reduce(0) { $0 + Int($1.usage?.modelCalls ?? 0) }
        info.pendingApprovals = c.permission != nil ? 1 : 0
        info.pendingSummary = c.permission.map { "\($0.name) \($0.arg)" }
        info.queuedMessages = c.queue.count
        info.cwd = c.status?.cwd ?? c.folder.path
        return info
    }

    /// The status of session `id`, as one structured answer — the same computation
    /// SessionStatus uses, for the sidebar and picker.
    func status(of id: String) async -> StatusInfo? {
        guard var info = await Self.readStatus(id, broker: self) else { return nil }
        info.queuedMessages = inbound[id] ?? 0
        return info
    }

    /// Messages queued in session `id`'s engine inbox, waiting for its next turn boundary.
    /// The sidebar's dot uses this: queued counts as running, not idle (bug 2d).
    func pendingInbound(_ id: String) -> Int {
        inbound[id] ?? 0
    }

    /// `ReadSession`: the last items of a session's transcript as text — assistant text, user
    /// inputs, tool calls with args, results capped at 400 chars. Live conversations read
    /// from their folded turns; dead ones from the log's recorded items.
    private static func readTranscript(_ id: String, lastN n: Int, kinds: [String], broker: SessionBroker) async -> String {
        let want = Set(kinds)
        // Live: the conversation holds every item already folded. Everything main-actor
        // happens in one hop; only the log-file read runs detached.
        let live: String? = await MainActor.run(body: {
            func keeps(_ kind: String) -> Bool { want.isEmpty || want.contains(kind) }
            func trim(_ text: String) -> String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.count > 400 ? String(t.prefix(400)) + "…" : t
            }
            guard let c = broker.liveConversation(id), c.isLive else { return nil }
            var lines: [String] = []
            for turn in c.turns {
                if keeps("message"), !turn.input.isEmpty { lines.append("USER: \(trim(turn.input))") }
                for item in turn.items {
                    switch item.kind {
                    case .message where keeps("message"):
                        lines.append("ASSISTANT: \(trim(item.text))")
                    case .reasoning where keeps("reasoning"):
                        lines.append("REASONING: \(trim(item.text))")
                    case .notice where keeps("notice"):
                        lines.append("NOTICE: \(trim(item.text))")
                    case .tool(let name, _) where keeps("tool"):
                        var line = "TOOL \(name)"
                        if let r = item.result {
                            let body = r.output.isEmpty ? r.display ?? "" : r.output
                            line += " -> \(r.outcome == .ok ? "ok" : String(describing: r.outcome)): \(trim(body))"
                        }
                        lines.append(line)
                    default:
                        break
                    }
                }
            }
            return lines.isEmpty ? "" : lines.suffix(n).joined(separator: "\n")
        })
        if let live {
            return live.isEmpty ? "(nothing recorded yet)" : live
        }
        // Dead or closed: the log's durable items.
        if let text = await Task.detached { Self.logItems(id, lastN: n, kinds: want) }.value {
            return text
        }
        return "(couldn't read session \(id))"
    }

    /// The last `n` transcript lines from a session's log file: turn inputs, messages,
    /// reasoning and tool calls with their outputs. Nil when the log can't be read.
    nonisolated private static func logItems(_ id: String, lastN n: Int, kinds: Set<String>) -> String? {
        let file = FrogPaths.sessions.appending(path: "\(id).jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        func keeps(_ kind: String) -> Bool { kinds.isEmpty || kinds.contains(kind) }
        func trim(_ text: String) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 400 ? String(t.prefix(400)) + "…" : t
        }
        var lines: [String] = []
        for line in text.split(separator: "\n") {
            guard let v = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let env = v["env"] as? [String: Any] else { continue }
            switch env["event"] as? String {
            case "turn_started" where keeps("message"):
                if let input = env["input"] as? String, !input.isEmpty { lines.append("USER: \(trim(input))") }
            case "item_completed":
                guard let item = env["item"] as? [String: Any], let type = item["type"] as? String else { continue }
                switch type {
                case "message" where keeps("message"):
                    if let t = item["text"] as? String { lines.append("ASSISTANT: \(trim(t))") }
                case "reasoning" where keeps("reasoning"):
                    if let t = item["text"] as? String { lines.append("REASONING: \(trim(t))") }
                case "tool_call" where keeps("tool"):
                    let name = item["name"] as? String ?? "?"
                    let outcome = item["outcome"] as? String ?? "ok"
                    let output = (item["output"] as? String) ?? (item["display"] as? String) ?? ""
                    lines.append("TOOL \(name) -> \(outcome): \(trim(output))")
                default:
                    break
                }
            default:
                break
            }
        }
        let kept = lines.suffix(n)
        return kept.isEmpty ? "(nothing recorded yet)" : kept.joined(separator: "\n")
    }

    /// The conversation for session `id` when it's live (on screen or background).
    private func liveConversation(_ id: String) -> Conversation? {
        if let c = Library.shared.conversation(id), c.isLive { return c }
        if let c = background[id], c.isLive { return c }
        return nil
    }

    #if DEBUG
    /// Tests reach the transcript reader without a live engine.
    static func testTranscript(_ id: String, lastN n: Int, kinds: [String], broker: SessionBroker) async -> String {
        await readTranscript(id, lastN: n, kinds: kinds, broker: broker)
    }
    #endif

    /// The conversation tracked for session `id`: on screen or in the broker's background
    /// fleet (never started — StopSession must not wake a dead engine just to tell it to halt).
    private func tracked(_ id: String) -> Conversation? {
        if let c = Library.shared.conversation(id), c.isLive { return c }
        return background[id]
    }

    /// Report session `child`'s next turn back to `parent` when it goes idle (the hand-back).
    func watchStarted(_ child: String, reportTo parent: String) {
        guard !parent.isEmpty else { return }
        watches[child, default: []].append(Watch(sender: parent, armed: false, anyTurn: true))
    }

    /// How much of a session's last reply goes into its idle report.
    static let reportLimit = 2000

    func list(excluding id: String? = nil) -> [Entry] {
        directory().filter { $0.id != id }.sorted { $0.modified > $1.modified }
    }

    /// Find a session by id (or a unique id prefix), else by name (case-insensitive).
    /// `includeArchived` also looks among archived sessions (to unarchive one).
    func resolve(_ to: String, includeArchived: Bool = false) -> Result<Entry, BrokerError> {
        let key = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(BrokerError("`to` is empty")) }
        let all = includeArchived ? directoryIncludingArchived() : directory()
        if let e = all.first(where: { $0.id == key }) { return .success(e) }
        let named = all.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 {
            return .failure(BrokerError("\(named.count) sessions are named \"\(key)\": use an id (\(named.map(\.id).joined(separator: ", ")))"))
        }
        let prefixed = key.count >= 6 ? all.filter { $0.id.hasPrefix(key) } : []
        if prefixed.count == 1 { return .success(prefixed[0]) }
        return .failure(BrokerError("No session \"\(key)\". ListSessions shows what's there."))
    }

    func send(from sender: String, name: String, to: String, message: String, notifyWhenIdle: Bool) -> Result<Entry, BrokerError> {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .failure(BrokerError("`message` is empty")) }
        let target: Entry
        switch resolve(to) {
        case .success(let e): target = e
        case .failure(let e): return .failure(e)
        }
        guard target.id != sender else { return .failure(BrokerError("That's this session.")) }
        if let e = charge(sender) { return .failure(e) }
        guard reach(target.id, sender, name, message) else {
            return .failure(BrokerError("Couldn't reach \(target.name): its folder may be gone."))
        }
        // The message sits in the target's inbox until its next turn boundary: a queued
        // message keeps it "running" in the status truth (bug 2d).
        inbound[target.id, default: 0] += 1
        Library.shared.reportQueued(target.id)
        if notifyWhenIdle {
            watches[target.id, default: []].append(Watch(sender: sender, armed: false))
        }
        return .success(target)
    }

    /// Count one send against `sender`'s limit; an error once it's spent.
    private func charge(_ sender: String) -> BrokerError? {
        let cutoff = now().addingTimeInterval(-Self.rateWindow)
        var times = (sent[sender] ?? []).filter { $0 > cutoff }
        guard times.count < Self.rateLimit else {
            sent[sender] = times
            onLimit(sender)
            return BrokerError("Rate limit: \(Self.rateLimit) messages in \(Int(Self.rateWindow / 60)) minutes without the user. Stop and wait for the user.")
        }
        times.append(now())
        sent[sender] = times
        return nil
    }

    /// The user did something in session `id`: its sends start over.
    func userActivity(_ id: String) {
        sent[id] = nil
    }

    // MARK: Live state

    /// A session's live state changed (from `Library.report`).
    func observe(_ id: String, running: Bool, waiting: Bool) {
        if running {
            // The engine is working a turn: anything we queued into its inbox has been taken.
            inbound[id] = 0
            if var list = watches[id] {
                let input = currentInput(id)
                for i in list.indices where input == nil || list[i].anyTurn || input!.hasPrefix("<session-message from=\"\(list[i].sender)\"") {
                    list[i].armed = true
                }
                watches[id] = list
            }
            if background[id] != nil { armedBackground.insert(id) }
            return
        }
        guard !waiting else { return }
        let dead = background[id]?.failure != nil
        // A started session whose first turn never made a model call (cancelled at birth, or
        // its engine died first): its first prompt is replayed, so the work it was started for
        // isn't silently lost. Checked before anything reports it idle.
        if var b = births[id] {
            if firstTurnRan(id) {
                births[id] = nil
                saveBirths()
            } else if dead || !targetBusy(id) {
                guard b.attempts < Self.birthRetries else {
                    births[id] = nil
                    saveBirths()
                    return
                }
                b.attempts += 1
                births[id] = b
                saveBirths()
                if dead { background[id] = nil }
                _ = replayPrompt(id, b.prompt)
                return
            }
        }
        // An engine that died mid-turn (its process gone, no `turn_ended`, a stale `.live`):
        // its conversation isn't live and its last turn is still open. Restart the engine and
        // have it pick the turn back up, rather than leaving the session stuck open forever.
        // The restarted turn runs and settles first; idle notices wait for that. (Before the
        // busy check: a dead engine's open turn looks busy.)
        if dead, let c = background[id], c.turns.last.map({ !$0.finished }) == true {
            background[id] = nil
            _ = conversation(for: id)
            return
        }
        // Idle only when nothing is running and nothing is queued: a live engine mid-turn
        // (or one with messages waiting) gets no notice, whatever the last report said.
        guard !targetBusy(id) else { return }
        if let list = watches[id] {
            let ready = list.filter(\.armed)
            watches[id] = list.filter { !$0.armed }
            if watches[id]?.isEmpty == true { watches[id] = nil }
            let name = directory().first { $0.id == id }?.name ?? id
            for w in ready {
                let report = lastReport(id).map { "\n\nIts last reply:\n\($0)" } ?? ""
                _ = reach(w.sender, "system", "system", "Session \"\(name)\" (\(id)) is idle.\(report)")
            }
        }
        // A background engine that did its work lets go; a new message starts it again.
        // Never while a turn is open (a just-started child's first turn is), or while its
        // engine is still working — that was the cancel-at-birth bug.
        if armedBackground.remove(id) != nil, let c = background.removeValue(forKey: id) {
            let turnOpen = c.turns.last.map { !$0.finished } ?? false
            if turnOpen || c.busy {
                // Still working: keep it, and re-arm so the next real idle lets it go.
                background[id] = c
                armedBackground.insert(id)
            } else {
                c.stop()
            }
        }
    }

    // MARK: Engines

    /// A running conversation for session `id`: on screen, in the background, or started now.
    /// Restarting a closed one resumes its log: no mode flag (the engine keeps the mode the
    /// session last used) and no `-m` (it keeps the model it last ran on), never the sender's.
    /// A turn the dead engine left unfinished (it died mid-turn: no `turn_ended`, a stale
    /// `.live`) is picked back up rather than left open forever.
    func conversation(for id: String, continueOpen: Bool = true) -> Conversation? {
        if let c = Library.shared.conversation(id), c.isLive { return c }
        if let c = background[id], c.isLive { return c }
        guard let info = Library.shared.sessions.first(where: { $0.id == id }), let folder = info.folder else { return nil }
        // An engine that died mid-turn left it open: the fresh engine continues it, ahead of
        // anything new (the user may have stopped the old one; the report says which).
        let unfinished = background[id].map { c in c.turns.last.map { !$0.finished } ?? false } ?? false
        let c = Conversation(folder: folder, arguments: ["-r", id] + Workspace.engineFlags(chat: info.isChat, mode: false), model: nil)
        background[id] = c
        // A fresh engine has an empty inbox; its session's queued count starts over.
        inbound[id] = 0
        if unfinished, continueOpen { c.continueInterrupted() }
        return c
    }

    /// A pane opening session `id` takes over its background engine instead of starting another.
    func adopt(_ id: String) -> Conversation? {
        armedBackground.remove(id)
        guard let c = background.removeValue(forKey: id), c.isLive else { return nil }
        return c
    }

    /// A pane is letting go of `c`: keep it running in the background if it's busy and part of
    /// a group of sessions, rather than stopping it mid-task. True if kept.
    func keep(_ c: Conversation) -> Bool {
        guard c.busy, c.isLive, let id = c.sessionID, Library.shared.isAgentSession(id) else { return false }
        background[id] = c
        armedBackground.insert(id)
        return true
    }

    func track(_ c: Conversation, as id: String) {
        background[id] = c
    }

    private func name(of c: Conversation) -> String {
        if let t = c.title { return t }
        guard let id = c.sessionID else { return "" }
        return Library.shared.sessions.first { $0.id == id }?.displayTitle ?? ""
    }

    static func json(_ entries: [Entry]) -> JSONValue {
        .array(entries.map { e in
            var o: [String: JSONValue] = ["id": .string(e.id), "name": .string(e.name), "state": .string(e.state)]
            if let c = e.cwd { o["cwd"] = .string(c) }
            if let m = e.model { o["model"] = .string(m) }
            return .object(o)
        })
    }

    // MARK: Worktrees

    /// The branch a new session's worktree starts from: the repo's remote default
    /// (`origin/HEAD`, e.g. origin/main), so a session forked from a feature-branch checkout
    /// doesn't inherit its half-finished work. Falls back to the current branch only when
    /// there's no remote, and says so.
    nonisolated static func worktreeBase(in repo: URL) throws -> (ref: String, fallback: Bool) {
        let remoteHead = try? git(["rev-parse", "--symbolic-full-name", "origin/HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteHead, !remoteHead.isEmpty, remoteHead != "origin/HEAD" {
            return (remoteHead, false)
        }
        // `origin/HEAD` unset or missing: name the remote's main-ish branch directly.
        let remoteBranches = ((try? git(["branch", "--remote", "--format=%(refname:short)"], in: repo)) ?? "")
            .split(separator: "\n").map(String.init)
        for candidate in remoteBranches where candidate == "origin/main" || candidate == "origin/master" {
            return ("refs/remotes/\(candidate)", false)
        }
        guard remoteBranches.isEmpty else {
            throw BrokerError("no origin/main or origin/master to base the worktree on; branch manually and use cwd")
        }
        let current = try git(["branch", "--show-current"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        return (current.isEmpty ? "HEAD" : current, true)
    }

    /// A git worktree for a new session: `<repo>/.frog/worktrees/<name>` on a new branch
    /// `frog/<name>` from the remote default branch (a numbered name if taken). Returns its
    /// folder, branch, and the base ref it started from.
    nonisolated static func makeWorktree(from folder: URL, name: String) throws -> (URL, String, String) {
        let top = try git(["rev-parse", "--show-toplevel"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else { throw BrokerError("\(folder.path) isn't in a git repository") }
        let repo = URL(fileURLWithPath: top)
        let (baseRef, fallback) = try worktreeBase(in: repo)
        let base = slug(name)
        let branches = Set(try git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init))
        var n = 1
        var pick = base
        let root = repo.appending(path: ".frog/worktrees")
        while FileManager.default.fileExists(atPath: root.appending(path: pick).path) || branches.contains("frog/\(pick)") {
            n += 1
            pick = "\(base)-\(n)"
        }
        let dir = root.appending(path: pick)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["worktree", "add", "--quiet", "-b", "frog/\(pick)", dir.path, baseRef], in: repo)
        if fallback {
            // No remote: the best base available is this checkout's branch. Say so in the result.
            _ = baseRef
        }
        // Keep the worktrees out of the main checkout's `git status`.
        if let common = try? git(["rev-parse", "--git-common-dir"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) {
            let gitDir = common.hasPrefix("/") ? URL(fileURLWithPath: common) : repo.appending(path: common)
            let exclude = gitDir.appending(path: "info/exclude")
            let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
            if !current.contains("/.frog/worktrees/") {
                try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.frog/worktrees/\n")
                    .write(to: exclude, atomically: true, encoding: .utf8)
            }
        }
        return (dir, "frog/\(pick)", baseRef)
    }

    nonisolated static func slug(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(lowered).split(separator: "-").joined(separator: "-")
        let short = String(joined.prefix(40))
        return short.isEmpty ? "session" : short
    }

    @discardableResult
    nonisolated static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw BrokerError("git \(args.first ?? ""): \(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension SessionBroker {
    /// Wire the broker to the app: the library's sessions, engines, and new conversations.
    func install() {
        directory = {
            let lib = Library.shared
            return lib.sessions.filter { !lib.archived.contains($0.id) }.map { s in
                let c = lib.conversation(s.id)
                let state = switch lib.live[s.id] {
                case .running?: "running"
                case .waiting?: "waiting"
                default: "idle"
                }
                return Entry(
                    id: s.id, name: c?.title ?? s.displayTitle, state: state, cwd: s.cwd,
                    model: c?.status?.model ?? s.model, modified: s.modified)
            }
        }
        directoryIncludingArchived = {
            let lib = Library.shared
            return lib.sessions.map { s in
                let c = lib.conversation(s.id)
                let state = switch lib.live[s.id] {
                case .running?: "running"
                case .waiting?: "waiting"
                default: "idle"
                }
                return Entry(
                    id: s.id, name: c?.title ?? s.displayTitle, state: state, cwd: s.cwd,
                    model: c?.status?.model ?? s.model, modified: s.modified)
            }
        }
        archiver = { id, on in
            Library.shared.setArchived(id, on)
            Library.shared.refresh()
        }
        reach = { [unowned self] id, from, name, message in
            guard let c = conversation(for: id) else { return false }
            c.deliver(from: from, name: name, message: message)
            return true
        }
        onLimit = { id in
            Library.shared.conversation(id)?.note(
                "Paused messaging other sessions: \(SessionBroker.rateLimit) messages in 10 minutes without you. Send a message here to let it carry on.",
                warning: true)
        }
        currentInput = { id in Library.shared.conversation(id)?.turns.last?.input }
        targetBusy = { id in
            guard let c = Library.shared.conversation(id) ?? self.background[id] else { return false }
            return c.busy || c.turns.last.map { !$0.finished } == true || !c.queue.isEmpty
        }
        firstTurnRan = { [unowned self] id in
            guard let c = Library.shared.conversation(id) ?? self.background[id] else {
                return Self.logShowsAModelCall(id)
            }
            return c.turns.contains { ($0.usage?.modelCalls ?? 0) > 0 }
        }
        replayPrompt = { [unowned self] id, prompt in
            // The engine resumes the log (or restarts if it died); the prompt runs as its next
            // turn once the history is in. An open turn isn't continued as well: this is it.
            guard let c = conversation(for: id, continueOpen: false) else { return false }
            c.submit(prompt)
            return true
        }
        birthsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Frog/births.json")
        loadBirths()
        // Births left over from a previous run (the app quit or crashed before a child's
        // first turn ran): replay those whose logs show no model call, once sessions load.
        if !births.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                for (id, b) in self.births {
                    if Self.logShowsAModelCall(id) {
                        self.births[id] = nil
                    } else if self.conversation(for: id) == nil {
                        self.births[id] = nil
                    } else {
                        _ = self.replayPrompt(id, b.prompt)
                    }
                }
                self.saveBirths()
            }
        }
        lastReport = { id in
            guard let t = (Library.shared.conversation(id) ?? self.background[id])?.turns.last else { return nil }
            var text = t.items.filter { $0.kind == .message }.map(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > Self.reportLimit { text = String(text.suffix(Self.reportLimit)) + "\n(… earlier text cut)" }
            let ended = t.end.map { "\n(turn ended: \(String(describing: $0)))" } ?? ""
            return text.isEmpty && ended.isEmpty ? nil : text + ended
        }
        starter = { [unowned self] req, parent in try await start(req, parent: parent) }
        Conversation.sessionRequests = { [unowned self] c, r in handle(r, from: c) }
        Conversation.userActivity = { [unowned self] c in if let id = c.sessionID { userActivity(id) } }
    }

    /// `ArchiveSession`/`UnarchiveSession`: the sidebar's archive, as a broker operation. Hides
    /// from lists and sidebars; never deletes the log.
    func archive(_ id: String, _ on: Bool) {
        archiver(id, on)
    }

    /// The full structured status of session `id` (SessionStatus). Reads the live conversation
    /// when there is one, else the session log's tail — the same fields either way, so a dead
    /// engine's session still answers (state "dead", its last turn as the log left it).
    private static func readStatus(_ id: String, broker: SessionBroker) async -> StatusInfo? {
        var info = StatusInfo()
        let lib = Library.shared
        let conv = lib.conversation(id) ?? broker.background[id]
        let entry = lib.sessions.first { $0.id == id }
        guard entry != nil || conv != nil else { return nil }
        info.cwd = entry?.cwd ?? conv?.folder.path
        if let c = conv, c.isLive {
            // Live: everything comes from the folded events.
            info.engineAlive = true
            info.turnRunning = c.busy || c.turns.last.map { !$0.finished } == true
            info.turn = c.turns.last?.number.map(Int.init)
            info.turnSeconds = c.turns.last?.startedAt.map { Int(Date().timeIntervalSince($0)) }
            info.waiting = c.permission != nil || c.elicitation != nil || c.question != nil
            info.lastEnd = c.turns.last?.end.map { String(describing: $0) }
            info.model = c.status?.model ?? entry?.model
            info.mode = c.status?.mode.rawValue
            info.modelCalls = c.turns.reduce(0) { $0 + Int($1.usage?.modelCalls ?? 0) }
            if let p = c.permission {
                info.pendingApprovals = 1
                info.pendingSummary = "\(p.name) \(p.arg)"
            }
        } else {
            // Dead or closed: the log's tail answers what it can.
            info.engineAlive = false
            if let c = conv { info.lastEnd = c.turns.last?.end.map { String(describing: $0) } }
            info.model = entry?.model
            let tail = await Task.detached { Self.logTail(id) }.value
            if let (model, mode, modelCalls, lastEnd) = tail {
                info.model = info.model ?? model
                info.mode = mode
                info.modelCalls = modelCalls
                info.lastEnd = info.lastEnd ?? lastEnd
            }
        }
        // Worktrees report their branch, commits ahead of origin/main, and dirty files.
        if let cwd = info.cwd.map({ URL(fileURLWithPath: $0) }) {
            let (branch, ahead, dirty) = await Git.quick(cwd)
            info.branch = branch
            info.ahead = ahead
            info.dirty = dirty
        }
        return info
    }

    /// The model, mode, model-call count and last turn end from a session's log, without
    /// folding the whole history: the last `model_changed`/`mode_changed`, the summed
    /// `turn_ended` usage, and the last `turn_ended` reason. Nil when the log can't be read.
    nonisolated private static func logTail(_ id: String) -> (String?, String?, Int, String?)? {
        let file = FrogPaths.sessions.appending(path: "\(id).jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var model: String?
        var mode: String?
        var calls = 0
        var lastEnd: String?
        for line in text.split(separator: "\n") {
            guard let v = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let env = v["env"] as? [String: Any] else { continue }
            switch env["event"] as? String {
            case "model_changed": model = env["model"] as? String
            case "mode_changed": mode = env["mode"] as? String
            case "turn_ended":
                if let usage = env["usage"] as? [String: Any] {
                    calls += (usage["model_calls"] as? Int) ?? 0
                }
                if let reason = env["reason"] as? [String: Any], let type = reason["type"] as? String {
                    lastEnd = type
                }
            default: break
            }
        }
        return (model, mode, calls, lastEnd)
    }

    /// `StartSession`: a new conversation (in a worktree if asked), titled, with its first
    /// prompt, filed under its parent in the sidebar.
    private func start(_ req: StartRequest, parent: Conversation?) async throws -> Started {
        let title = req.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !req.prompt.isEmpty else { throw BrokerError("`title` and `prompt` are required") }
        var folder = parent?.folder ?? FileManager.default.homeDirectoryForCurrentUser
        if let cwd = req.cwd, !cwd.isEmpty {
            let path = (cwd as NSString).expandingTildeInPath
            folder = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw BrokerError("No folder at \(folder.path)")
        }
        var branch: String?
        var base: String?
        if req.worktree {
            let from = folder
            let (dir, b, basedOn) = try await Task.detached { try Self.makeWorktree(from: from, name: title) }.value
            folder = dir
            branch = b
            base = basedOn
        }
        let model = req.model ?? parent?.status?.model
        // The first prompt is on disk before the engine starts: if turn 1 dies at birth, it's
        // replayed rather than lost (see `births`).
        let pending = "pending-" + UUID().uuidString
        recordBirth(pending, prompt: req.prompt)
        let c = Conversation(folder: folder, arguments: Workspace.engineFlags(chat: false), model: model)
        guard c.failure == nil else {
            births[pending] = nil
            saveBirths()
            throw BrokerError(c.failure ?? "couldn't start")
        }
        c.rename(title)
        c.submit(req.prompt)
        let deadline = ContinuousClock.now + .seconds(20)
        while c.sessionID == nil, c.failure == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        births[pending] = nil
        guard let id = c.sessionID else {
            saveBirths()
            c.stop()
            throw BrokerError(c.failure ?? "the new session didn't start in time")
        }
        recordBirth(id, prompt: req.prompt)
        track(c, as: id)
        if let p = parent?.sessionID { Library.shared.setParent(of: id, to: p) }
        Library.shared.refresh()
        var started = Started(id: id, name: title, cwd: folder.path, branch: branch)
        started.base = base
        return started
    }
}

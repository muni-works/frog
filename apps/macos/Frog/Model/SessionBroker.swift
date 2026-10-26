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
        /// Worktree info, when asked for (ListSessions fields: branch, ahead, dirty).
        var branch: String?
        var ahead: Int?
        var dirty: Int?
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
        /// What the live engine runs degraded on, with why (its `Status.degraded`).
        var degraded: [Degraded] = []

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
            if !degraded.isEmpty {
                o["degraded"] = .array(degraded.map {
                    .object(["kind": .string($0.kind), "what": .string($0.what), "why": .string($0.why)])
                })
            }
            return .object(o)
        }
    }

    /// What `StartSession` asked for.
    struct StartRequest: Equatable {
        var title: String
        var prompt: String
        var cwd: String?
        var model: String?
        /// "default", "accept-edits", "auto" or "yolo" (only when asked for explicitly).
        var mode: String?
        var worktree: Bool
        /// Run in the user's main checkout anyway (worker sessions belong in worktrees).
        var allowMainCheckout = false
    }

    struct Started: Equatable {
        var id: String
        var name: String
        var cwd: String
        var branch: String?
        /// The ref the worktree started from (`origin/main`, say), for the tool result.
        var base: String?
    }

    /// ListSessions filters: a small, bounded answer instead of every row.
    struct ListFilter: Equatable {
        var cwdPrefix: String?
        var state: String?
        /// Unix seconds; only sessions active after this.
        var since: Int?
        var limit: Int
        var fields: [String]

        /// The default row cap: a chief's ListSessions never dumps the whole app.
        static let defaultLimit = 30

        init(input: JSONValue) {
            cwdPrefix = input["cwd_prefix"]?.string
            state = input["state"]?.string
            since = input["since"]?.int
            limit = min(max(input["limit"]?.int ?? Self.defaultLimit, 1), 100)
            fields = (input["fields"]?.array ?? []).compactMap(\.string)
        }

        func apply(to entries: [Entry], now: Date) -> [Entry] {
            let sinceDate = since.map { Date(timeIntervalSince1970: Double($0)) }
            return entries.filter { e in
                if let p = cwdPrefix, !(e.cwd ?? "").hasPrefix(p) { return false }
                if let s = state, e.state != s { return false }
                if let d = sinceDate, e.modified < Int(d.timeIntervalSince1970 * 1000) { return false }
                return true
            }
            .prefix(limit)
            .map { $0 }
        }
    }

    /// Worktree git info for each row that asked for it (fields: branch, ahead, dirty).
    private static func withGit(_ rows: [Entry]) async -> [Entry] {
        var out: [Entry] = []
        for var e in rows {
            if let cwd = e.cwd.map({ URL(fileURLWithPath: $0) }) {
                let (branch, ahead, dirty) = await Git.quick(cwd)
                e.branch = branch
                e.ahead = ahead
                e.dirty = dirty
            }
            out.append(e)
        }
        return out
    }

    /// Messages a session may send (or sessions it may start) without the user doing anything.
    static let rateLimit = 30
    static let rateWindow: TimeInterval = 10 * 60

    var directory: () -> [Entry] = { [] }
    /// Like `directory`, but including archived sessions (to resolve one for unarchiving).
    var directoryIncludingArchived: () -> [Entry] = { [] }
    /// Hide (or show) a session in the sidebar, exactly like the sidebar's own archive.
    var archiver: (_ id: String, _ on: Bool) -> Void = { _, _ in }
    /// `MoveSession`: re-file a session under a new parent (nil unparents; a top-level row
    /// again). Parentage is the app's (Library's `sessionParents`), so the move is a closure
    /// like the archiver; refusal (a session nested under its own descendant) comes back as
    /// the error the model sees. The recorded parent on success.
    var mover: (_ id: String, _ parent: String?) -> Result<String?, BrokerError> = { _, _ in
        .failure(BrokerError("moving sessions isn't available"))
    }
    /// Deliver an op to session `id`, starting its engine if needed. False if it can't be reached.
    var reach: (_ id: String, _ from: String, _ fromName: String, _ message: String) -> Bool = { _, _, _, _ in false }
    /// Hand session `id` a status-only message (read, no turn). False if it can't be reached.
    var inform: (_ id: String, _ from: String, _ fromName: String, _ message: String) -> Bool = { _, _, _, _ in false }
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
    /// The conversation a window shows for session `id`, if any (the app's `Library`); the
    /// broker's own background engines are in `background`.
    var windowConversation: (_ id: String) -> Conversation? = { _ in nil }
    /// What session `id` said and how its last turn ended, for the report a watcher gets when
    /// it goes idle (the hand-back from a session it started or messaged).
    var lastReport: (_ id: String) -> String? = { _ in nil }
    /// Inbound session messages waiting in a target engine's inbox, by session id. Counted
    /// here because the engine holds them; bumped on send, cleared when the target runs
    /// them (its turn starts) or is restarted dead. The messages themselves ride along, so
    /// an update's restart can re-send the ones its engine never ran.
    private var inbound: [String: Int] = [:]
    private var pendingInbox: [String: [(String, String, String)]] = [:]
    /// When each session's current permission card arrived (ListApprovals reports its age).
    private var waitingSince: [String: Date] = [:]
    /// The session that started session `id`, if one did (pending approvals escalate to it).
    /// The session that started session `id`, if one did (pending approvals escalate to it).
    var parentOf: (_ id: String) -> String? = { _ in nil }


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
    /// Background engines seen running: stopped once they've sat settled for `idleGrace`.
    private var armedBackground: Set<String> = []
    /// How long a background engine must stay settled (see `Conversation.settled`) before it's
    /// let go. An `idle` follows every op the engine handles (startup, `subscribe`, a rename,
    /// a mode change, a turn's end), so letting go on the first one stopped engines at a turn
    /// boundary with a delivered message about to run, and cancelled it.
    var idleGrace: Duration = .seconds(30)
    /// Runs `work` after `delay` on the main actor (tests run it by hand).
    var after: (_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            work()
        }
    }
    /// Per session, bumped whenever it's seen working (or its engine is replaced): a scheduled
    /// idle stop only fires if nothing happened since it was scheduled.
    private var idleEpoch: [String: Int] = [:]

    /// A background engine may be let go: nothing running, queued, or still starting up.
    private func canLetGo(_ c: Conversation) -> Bool {
        guard c.settled else { return false }
        guard let id = c.sessionID else { return true }
        return !targetBusy(id)
    }

    /// Let background engine `c` (session `id`) go once it's been settled for `idleGrace`,
    /// unless it works, is adopted by a pane, or is replaced meanwhile.
    private func scheduleIdleStop(_ id: String, _ c: Conversation) {
        guard canLetGo(c) else { return }
        idleEpoch[id, default: 0] += 1
        let epoch = idleEpoch[id]
        let grace = idleGrace
        after(grace) { [weak self, weak c] in
            guard let self, let c, self.idleEpoch[id] == epoch,
                  self.background[id] === c, self.armedBackground.contains(id),
                  self.canLetGo(c) else { return }
            self.armedBackground.remove(id)
            self.background[id] = nil
            c.stop(reason: "background idle (settled \(grace))")
        }
    }

    /// Session `id` is working (or its engine changed): any idle stop scheduled for it is off.
    private func touch(_ id: String) {
        idleEpoch[id, default: 0] += 1
    }

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
        case "ListSessions": {
            // Filters (cwd_prefix, state, since, fields) with a default limit of 30: never
            // the ~150-row dump the unfiltered listing was. Branch info (branch, ahead,
            // dirty) costs a git call per worktree row, so only when asked for.
            let filter = Self.ListFilter(input: input)
            let base = list(excluding: sender)
            let rows = filter.apply(to: base, now: now())
            let wantGit = !filter.fields.filter { ["branch", "ahead", "dirty"].contains($0) }.isEmpty
            if !wantGit {
                c.replySession(r.id, result: Self.json(rows, fields: filter.fields))
                return
            }
            Task { [weak c] in
                let enriched = await Self.withGit(rows)
                c?.replySession(r.id, result: Self.json(enriched, fields: filter.fields))
            }
        }()
        case "SendMessage":
            let result = send(
                from: sender, name: name(of: c),
                to: input["to"]?.string ?? "", message: input["message"]?.string ?? "",
                notifyWhenIdle: input["notify_when_idle"]?.bool ?? false,
                informational: input["informational"]?.bool ?? false)
            switch result {
            case .success(let e) where input["informational"]?.bool == true:
                c.replySession(r.id, result: .string("Sent to \(e.name) (\(e.id)) as informational: recorded as read, no turn starts for it; it sees the message with its next turn."))
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
                mode: input["mode"]?.string,
                worktree: input["worktree"]?.bool ?? false,
                allowMainCheckout: input["allow_main_checkout"]?.bool ?? false)
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
                // An archived session's queued messages never run: one left behind restarted
                // a stopped session, which then deleted work in its tree.
                let dropped = on ? clearQueue(e.id) : 0
                archive(e.id, on)
                let cancelled = dropped > 0 ? " \(Self.cancelled(dropped))." : ""
                c.replySession(r.id, result: .string(
                    "\(on ? "Archived" : "Unarchived") \(e.name) (\(e.id)).\(on ? " Its log is kept; UnarchiveSession brings it back.\(cancelled)" : " It's back in the sidebar.")"))
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
            // `clear_queue` also cancels its inbox, so no queued message starts the next turn.
            switch resolve(input["id"]?.string ?? "") {
            case .success(let e):
                guard e.id != sender else { return c.replySession(r.id, error: "That's this session: use your own stop.") }
                let target = tracked(e.id)
                let running = target.map { $0.busy || e.state == "running" || e.state == "waiting" } ?? false
                let cleared = (input["clear_queue"]?.bool ?? false)
                    ? " \(Self.cancelled(clearQueue(e.id))), so nothing restarts it." : ""
                guard let target else {
                    c.replySession(r.id, result: .string("\(e.name) (\(e.id)) has no live engine; nothing to stop.\(cleared)"))
                    return
                }
                guard running else {
                    c.replySession(r.id, result: .string("\(e.name) (\(e.id)) isn't running; nothing to stop.\(cleared)"))
                    return
                }
                target.interrupt()
                c.replySession(r.id, result: .string("Stopping \(e.name) (\(e.id)): its turn ends cancelled and it goes idle.\(cleared)"))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "SetSessionMode":
            // Never above the caller's own mode (a child can't grant itself more than its
            // parent has), and yolo additionally needs an explicit flag.
            switch resolve(input["id"]?.string ?? "") {
            case .success(let e):
                guard let raw = input["mode"]?.string, let wanted = Mode(rawValue: raw) else {
                    return c.replySession(r.id, error: "`mode` must be default, accept-edits, auto or yolo.")
                }
                // The ceiling holds whether or not an engine is running: a stored mode is
                // applied at the next start just as a live one would be now.
                let mine = c.status?.mode ?? .default
                if wanted.rank > mine.rank {
                    return c.replySession(r.id, error: "You're in \(mine.rawValue) mode; you can't raise another session to \(wanted.rawValue).")
                }
                if wanted == .yolo, mine != .yolo || input["yolo"]?.bool != true {
                    return c.replySession(r.id, error: "Setting a session to yolo needs mode: \"yolo\" and an explicit yolo: true.")
                }
                guard let target = tracked(e.id) else {
                    // No engine running: persist the mode so the next engine start picks it up.
                    Library.shared.setStoredMode(e.id, wanted)
                    return c.replySession(r.id, result: .string("\(e.name) (\(e.id)) set to \(wanted.rawValue) mode; persisted (applies next start)."))
                }
                target.setMode(wanted)
                c.replySession(r.id, result: .string("\(e.name) (\(e.id)) is now in \(wanted.rawValue) mode (from its next turn)."))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "SetSessionModel":
            switch resolve(input["id"]?.string ?? "") {
            case .success(let e):
                guard let model = input["model"]?.string, !model.isEmpty else {
                    return c.replySession(r.id, error: "`model` is required (provider/model, e.g. local/qwen3-4b).")
                }
                guard let target = tracked(e.id) else {
                    // No engine running: persist the model so the next engine start picks it up.
                    Library.shared.setStoredModel(e.id, model)
                    return c.replySession(r.id, result: .string("\(e.name) (\(e.id)) set to \(model); persisted (applies next start)."))
                }
                target.setModel(model)
                c.replySession(r.id, result: .string("\(e.name) (\(e.id)) moves to \(model) (from its next model call)."))
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "ListApprovals":
            // Read-only: pending permission cards across every session. Approving stays the
            // user's job — the caller sees what's waiting, it never answers it.
            let rows: [JSONValue] = approvals().map { row in
                .object([
                    "session": .string(row.id),
                    "name": .string(row.name),
                    "command": .string(row.command),
                    "tool": .string(row.tool),
                    "reason": .string(row.reason),
                    "age_seconds": .number(Double(row.ageSeconds)),
                ] as [String: JSONValue])
            }
            let note = rows.isEmpty
                ? "No pending approvals."
                : "\(rows.count) pending approval\(rows.count == 1 ? "" : "s"). Approving is the user's job; don't answer them yourself."
            c.replySession(r.id, result: .object(["approvals": .array(rows), "note": .string(note)]))
        case "RenameSession":
            switch resolve(input["id"]?.string ?? "", includeArchived: true) {
            case .success(let e):
                let title = input["title"]?.string ?? ""
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return c.replySession(r.id, error: "`title` is required.")
                }
                // An open conversation renames through its engine (Op.setTitle, the sidebar's
                // own path); a closed one through the CLI, which writes the session's log.
                if let target = tracked(e.id) {
                    target.rename(trimmed)
                    Library.shared.refresh()
                    c.replySession(r.id, result: .string("Renamed \(e.id) to \"\(trimmed)\"."))
                } else {
                    Task { [weak c] in
                        await Library.shared.rename(e.id, to: trimmed)
                        c?.replySession(r.id, result: .string("Renamed \(e.id) to \"\(trimmed)\"."))
                    }
                }
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        case "MoveSession":
            // Re-file a session under a new parent — the nesting the sidebar derives from.
            // Sidebar organization only: the log, model, mode and history stay the session's
            // own (a mis-filed session stops being stuck). nil/absent parent unparents.
            switch resolve(input["id"]?.string ?? "", includeArchived: true) {
            case .success(let e):
                let asked = (input["parent"]?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var parent: Entry?
                if !asked.isEmpty {
                    switch resolve(asked, includeArchived: true) {
                    case .success(let p): parent = p
                    case .failure(let err): return c.replySession(r.id, error: err.message)
                    }
                }
                // Moving under itself would erase its own parentage (a cycle).
                if let p = parent, p.id == e.id {
                    return c.replySession(r.id, error: "That's \(e.name) itself; a session can't be its own parent.")
                }
                switch mover(e.id, parent?.id) {
                case .failure(let err):
                    c.replySession(r.id, error: err.message)
                case .success(nil):
                    c.replySession(r.id, result: .string("Unparented \(e.name) (\(e.id)): it's a top-level row again."))
                case .success:
                    // The resolved entry, not the recorded id, so the model sees a name.
                    let who = parent.map { "\($0.name) (\($0.id))" } ?? "its new parent"
                    c.replySession(r.id, result: .string("Moved \(e.name) (\(e.id)) under \(who); the sidebar regroups."))
                }
            case .failure(let e):
                c.replySession(r.id, error: e.message)
            }
        default:
            c.replySession(r.id, error: "unknown session tool \(r.tool)")
        }
    }

    /// One pending approval, as ListApprovals reports it.
    struct Approval: Equatable {
        var id: String
        var name: String
        var command: String
        var tool: String
        var reason: String
        var ageSeconds: Int
    }

    /// Every session's pending permission card, oldest fact first. Read-only.
    func approvals() -> [Approval] {
        list().compactMap { entry in
            guard let conv = Library.shared.conversation(entry.id) ?? background[entry.id],
                  let p = conv.permission else { return nil }
            let since = waitingSince[entry.id] ?? now()
            return Approval(
                id: entry.id, name: entry.name, command: p.arg, tool: p.name,
                reason: p.reason ?? "", ageSeconds: Int(now().timeIntervalSince(since)))
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
        info.degraded = c.status?.degraded ?? []
        return info
    }

    /// The status of session `id`, as one structured answer — the same computation
    /// SessionStatus uses, for the sidebar and picker.
    func status(of id: String) async -> StatusInfo? {
        guard var info = await Self.readStatus(id, broker: self) else { return nil }
        info.queuedMessages = inbound[id] ?? 0
        return info
    }

    /// Nothing queued may (re)start session `id`: its engine drops its inbox (when one runs),
    /// and the broker forgets the queued count, the re-send list an update restart would
    /// replay, and a first prompt waiting to be replayed. Returns how many messages it
    /// cancelled. StopSession's `clear_queue` and every archive call it.
    @discardableResult
    func clearQueue(_ id: String) -> Int {
        let target = tracked(id)
        let dropped = max(inbound[id] ?? 0, pendingInbox[id]?.count ?? 0, target?.pendingDeliveries ?? 0)
        target?.clearInbox()
        inbound[id] = 0
        pendingInbox[id] = nil
        if births.removeValue(forKey: id) != nil { saveBirths() }
        return dropped
    }

    static func cancelled(_ n: Int) -> String {
        "Its inbox is cleared (\(n) queued message\(n == 1 ? "" : "s") cancelled)"
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

    /// Tests read the approval cards and their age tracking.
    var approvalsForTesting: [Approval] { approvals() }
    var waitingSinceForTesting: [String: Date] { waitingSince }
    #endif

    /// The conversation tracked for session `id`: on screen or in the broker's background
    /// fleet (never started — StopSession must not wake a dead engine just to tell it to halt).
    private func tracked(_ id: String) -> Conversation? {
        if let c = Library.shared.conversation(id), c.isLive { return c }
        return background[id]
    }

    /// Every live conversation the broker runs headless: sessions started for work that no
    /// window shows. The update drain must reach these too (a graceful restart used to
    /// suspend only what was on screen and let these engines' turns die as crashes).
    var liveBackground: [Conversation] {
        background.values.filter { $0.isLive }
    }

    /// A permission prompt opened in session `child`: tell the session that started it,
    /// so a manager can decide (or tell the user) instead of the prompt sitting unseen.
    /// The child waits on it until answered or its timeout takes the safe path.
    @discardableResult
    func escalate(_ req: PermissionRequest, from child: String, name: String) -> Bool {
        guard let parent = parentOf(child), parent != child else { return false }
        return reach(parent, "system", "system", Self.escalation(req, session: child, name: name))
    }

    /// The structured notice a parent gets for a child's pending approval.
    static func escalation(_ req: PermissionRequest, session: String, name: String) -> String {
        var lines = [
            "Approval pending in session \"\(name)\" (\(session)).",
            "card: \(req.id)",
            "tool: \(req.name)",
            "command: \(req.arg)",
        ]
        if let r = req.reason { lines.append("reason: \(r)") }
        if let c = req.card {
            if let a = c.agentReason { lines.append("agent says: \(a)") }
            lines.append("trigger: \(c.trigger)")
            for t in c.touches ?? [] {
                let size = t.bytes.map { " \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? ""
                let mine = t.createdHere == true ? " (made by this session)" : ""
                lines.append("touches: \(t.path)\(size)\(mine)")
            }
            lines.append("risk: \(c.risk)")
            lines.append("recommendation: \(c.recommendation)")
            lines.append("If nobody answers in \(c.timeoutSecs / 60) min it's denied and the session carries on.")
        }
        lines.append("Only the user can answer it, in that session's window; tell them if it matters.")
        return lines.joined(separator: "\n")
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

    func send(from sender: String, name: String, to: String, message: String, notifyWhenIdle: Bool, informational: Bool = false) -> Result<Entry, BrokerError> {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .failure(BrokerError("`message` is empty")) }
        let target: Entry
        switch resolve(to) {
        case .success(let e): target = e
        case .failure(let e): return .failure(e)
        }
        guard target.id != sender else { return .failure(BrokerError("That's this session.")) }
        if let e = charge(sender) { return .failure(e) }
        // Status only: read without a turn, so nothing sits in the inbox and no idle watch arms.
        if informational {
            guard inform(target.id, sender, name, message) else {
                return .failure(BrokerError("Couldn't reach \(target.name): its folder may be gone."))
            }
            return .success(target)
        }
        guard reach(target.id, sender, name, message) else {
            return .failure(BrokerError("Couldn't reach \(target.name): its folder may be gone."))
        }
        // The message sits in the target's inbox until its next turn boundary: a queued
        // message keeps it "running" in the status truth (bug 2d).
        inbound[target.id, default: 0] += 1
        pendingInbox[target.id, default: []].append((sender, name, message))
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
        if !unnamed.isEmpty { claimUnnamed(id) }
        // When the current permission card arrived, for its age in ListApprovals.
        if waiting {
            if waitingSince[id] == nil { waitingSince[id] = now() }
        } else {
            waitingSince[id] = nil
        }
        if running {
            touch(id)
            // The engine is working a turn: what it hasn't taken from its inbox yet is what's
            // still queued (messages delivered mid-turn wait for the next one).
            inbound[id] = (Library.shared.conversation(id) ?? background[id])?.pendingDeliveries ?? 0
            // What it HAS taken is off the re-send list: an update restart must not replay
            // messages the engine already ran.
            let taken = inbound[id] ?? 0
            if var list = pendingInbox[id] {
                list.removeFirst(min(taken, list.count))
                pendingInbox[id] = list.isEmpty ? nil : list
            }
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
                if dead {
                    background[id] = nil
                    armedBackground.remove(id)
                }
                _ = replayPrompt(id, b.prompt)
                return
            }
        }
        // A dead engine (killed mid-turn: no `turn_ended`, a stale `.live`) leaves the
        // session stuck busy — an open turn never settles and queued messages can never
        // flush. Reconcile from the log the way the window's own watchdog does: the turn
        // ends as the log says and the queued count clears, so delivered messages run when
        // an engine next starts (a user action; no auto-resume here).
        if let c = windowConversation(id) ?? background[id], !c.isLive,
           inbound[id] != 0 || !c.queue.isEmpty || c.turns.last.map({ !$0.finished }) == true {
            // Cleared here (not inside the async reconcile): callers reading the queued
            // count right after this report must see it drained.
            inbound[id] = 0
            Task { await c.reconcile() }
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
        // Only once it's truly settled (no open turn, nothing queued here or in its inbox, not
        // mid-resume) and has stayed so for `idleGrace`: never on the bare `idle` that follows
        // every op, which stopped engines at a turn boundary with a delivered message about
        // to run (cancelled at birth) and right after a resume.
        if armedBackground.contains(id), let c = background[id] {
            scheduleIdleStop(id, c)
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
        // A model or mode set while no engine ran (SetSessionModel/Mode) applies now, once.
        let stored = Library.shared.takeStored(id)
        let c = Conversation(folder: folder, arguments: Self.resumeArguments(id, chat: info.isChat),
                             model: stored.model)
        Self.apply(stored, to: c)
        background[id] = c
        // A fresh engine isn't armed until it's seen working; nothing scheduled for the old
        // one applies to it.
        armedBackground.remove(id)
        touch(id)
        // A fresh engine has an empty inbox; its session's queued count starts over.
        inbound[id] = 0
        // An update's restart is here: this session's engine never ran what was delivered
        // to the old one — re-send it (the manifest said the turn was suspended; this is
        // the inbox half). Anything queued before a plain restart was already re-sent by
        // the registry's `queued`; this list only fills between a send and a drain.
        if let unsent = pendingInbox[id], !unsent.isEmpty, SessionRegistry.shared.current.afterUpdate {
            pendingInbox[id] = nil
            inbound[id] = 0
            Task { @MainActor in
                // Give the fresh engine a beat to subscribe before the re-sends go.
                try? await Task.sleep(for: .milliseconds(600))
                for (from, name, message) in unsent {
                    guard let c = self.conversation(for: id) else { return }
                    c.deliver(from: from, name: name, message: message)
                }
            }
        } else {
            pendingInbox[id] = nil
        }
        if unfinished, continueOpen { c.continueInterrupted() }
        return c
    }

    /// The flags a closed session is resumed with: `-r` and the app-wide flags, never `-m` or
    /// a mode flag (the engine keeps the model and mode the session last used).
    static func resumeArguments(_ id: String, chat: Bool) -> [String] {
        ["-r", id] + Workspace.engineFlags(chat: chat, mode: false)
    }

    /// A stored override's part an engine takes after it starts: the mode. (The model goes in
    /// as `-m`, which a resumed engine honors; it resumes in its log's last mode whatever the
    /// flags say, so the mode is an op it takes at its first turn boundary.)
    static func apply(_ stored: (model: String?, mode: Mode?), to c: Conversation) {
        if let mode = stored.mode { c.setMode(mode) }
    }

    /// A pane opening session `id` takes over its background engine instead of starting another.
    func adopt(_ id: String) -> Conversation? {
        armedBackground.remove(id)
        touch(id)
        guard let c = background.removeValue(forKey: id), c.isLive else { return nil }
        return c
    }

    /// A pane is letting go of `c` (switched to another session or folder, closed): keep it
    /// running in the background while it has work, rather than stopping it mid-task. Any
    /// session, not only agents': what's on screen never decides whether a turn lives (a new
    /// thread switched away from during its first answer was cancelled before anything
    /// streamed). It lets go once settled, like any background engine. True if kept.
    func keep(_ c: Conversation) -> Bool {
        // A delivered message the engine hasn't started yet (between one turn's `idle` and the
        // next's start) or a message queued while it starts up would be cancelled. Live
        // background work (a Monitor, a job, a Task) would die with the engine. `busy` alone is
        // also an engine still starting up with nothing asked of it: that one can go.
        let asked = !c.turns.isEmpty || !c.queue.isEmpty
        let working = (c.busy && asked) || !c.queue.isEmpty || c.pendingDeliveries > 0
            || c.backgroundRunning > 0 || c.turns.last.map { !$0.finished } == true
        guard working, c.isLive else { return false }
        guard let id = c.sessionID else {
            // Its engine hasn't said which session it is yet: held until it does (`observe`).
            unnamed.removeAll { !$0.isLive }
            if !unnamed.contains(where: { $0 === c }) { unnamed.append(c) }
            return true
        }
        background[id] = c
        armedBackground.insert(id)
        touch(id)
        return true
    }

    /// Kept engines that hadn't named their session yet (see `keep`).
    private var unnamed: [Conversation] = []

    /// A kept engine just named its session `id`: it's that session's background engine now.
    private func claimUnnamed(_ id: String) {
        unnamed.removeAll { !$0.isLive }
        guard let i = unnamed.firstIndex(where: { $0.sessionID == id }) else { return }
        background[id] = unnamed.remove(at: i)
        armedBackground.insert(id)
        touch(id)
    }

    func track(_ c: Conversation, as id: String) {
        background[id] = c
    }

    private func name(of c: Conversation) -> String {
        if let t = c.title { return t }
        guard let id = c.sessionID else { return "" }
        return Library.shared.sessions.first { $0.id == id }?.displayTitle ?? ""
    }

    static func json(_ entries: [Entry], fields: [String] = []) -> JSONValue {
        let want = Set(fields)
        return .array(entries.map { e in
            var o: [String: JSONValue] = ["id": .string(e.id), "name": .string(e.name), "state": .string(e.state)]
            if let c = e.cwd { o["cwd"] = .string(c) }
            if let m = e.model { o["model"] = .string(m) }
            if want.contains("branch"), let b = e.branch { o["branch"] = .string(b) }
            if want.contains("ahead"), let a = e.ahead { o["ahead"] = .number(Double(a)) }
            if want.contains("dirty"), let d = e.dirty { o["dirty"] = .number(Double(d)) }
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

    /// Where a folder sits in git, for StartSession's checks (read from the files, no git run).
    enum Checkout: Equatable {
        /// Not in a repo, or a main checkout that has no `.frog/worktrees` (never used for workers).
        case plain
        /// The user's main checkout (`top`): it owns `.frog/worktrees`.
        case main(top: URL)
        /// A linked worktree (`top`), its private git dir holding the engine lock.
        case worktree(top: URL, gitDir: URL)
    }

    nonisolated static func checkout(of folder: URL) -> Checkout {
        let fm = FileManager.default
        var at = folder.standardizedFileURL
        while true {
            let dot = at.appending(path: ".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dot.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return fm.fileExists(atPath: at.appending(path: ".frog/worktrees").path) ? .main(top: at) : .plain
                }
                guard let text = try? String(contentsOf: dot, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return .plain }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : at.appending(path: path)
                // A submodule's `.git` file points at `.git/modules/…`: not a worktree.
                guard gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" else { return .plain }
                return .worktree(top: at, gitDir: gitDir.standardizedFileURL)
            }
            let up = at.deletingLastPathComponent()
            if up.path == at.path { return .plain }
            at = up
        }
    }

    /// The session whose engine holds a linked worktree (the engine's `frog-engine.lock` in
    /// its git dir, an flock that dies with the engine), if one does.
    nonisolated static func worktreeOwner(gitDir: URL) -> String? {
        let fd = open(gitDir.appending(path: "frog-engine.lock").path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let text = (try? String(contentsOf: gitDir.appending(path: "frog-engine.lock"), encoding: .utf8)) ?? ""
        return text.split(separator: " ").first.map(String.init) ?? "another session"
    }

    /// StartSession without `worktree:true`: refuse the user's main checkout (the repo root
    /// that owns `.frog/worktrees`, or anywhere in it) unless `allowMainCheckout`, and a
    /// worktree another engine runs in. An existing free worktree is used as-is (reuse).
    nonisolated static func checkWorkerFolder(_ folder: URL, allowMainCheckout: Bool) throws {
        switch checkout(of: folder) {
        case .plain:
            return
        case .main(let top):
            guard !allowMainCheckout else { return }
            let trees = ((try? FileManager.default.contentsOfDirectory(atPath: top.appending(path: ".frog/worktrees").path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted().prefix(3)
                .map { top.appending(path: ".frog/worktrees/\($0)").path }
            let reuse = trees.isEmpty ? "" : ", or reuse a worktree with cwd: \(trees.joined(separator: " or "))"
            throw BrokerError("\(folder.path) is the user's main checkout of \(top.path): worker sessions belong in worktrees, so two of them never mix work in the user's tree. Pass worktree:true for a fresh one\(reuse). allow_main_checkout:true overrides, only when the user asked for it.")
        case .worktree(let top, let gitDir):
            if let owner = worktreeOwner(gitDir: gitDir) {
                throw BrokerError("\(top.path) already has an engine: session \(owner) runs in it. One engine per worktree: pass worktree:true for a fresh one, or stop or archive \(owner) first.")
            }
        }
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
        mover = { id, parent in
            // No refresh: parentage isn't part of the sessions listing. `parents` is
            // observed, so the sidebar's grouping re-derives from the mutation itself.
            switch Library.shared.move(id, to: parent) {
            case .success(let recorded): return .success(recorded)
            case .failure(let refusal): return .failure(BrokerError(refusal.message))
            }
        }
        reach = { [unowned self] id, from, name, message in
            guard let c = conversation(for: id) else { return false }
            c.deliver(from: from, name: name, message: message)
            return true
        }
        inform = { [unowned self] id, from, name, message in
            guard let c = conversation(for: id) else { return false }
            c.inform(from: from, name: name, message: message)
            return true
        }
        onLimit = { id in
            Library.shared.conversation(id)?.note(
                "Paused messaging other sessions: \(SessionBroker.rateLimit) messages in 10 minutes without you. Send a message here to let it carry on.",
                warning: true)
        }
        currentInput = { id in Library.shared.conversation(id)?.turns.last?.input }
        windowConversation = { id in Library.shared.conversation(id) }
        targetBusy = { id in
            guard let c = Library.shared.conversation(id) ?? self.background[id] else { return false }
            return c.busy || c.turns.last.map { !$0.finished } == true || !c.queue.isEmpty
                || c.pendingDeliveries > 0
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
        // TODO(item 3, carried forward): the rescue op's broker half — start a session whose
        // opening context is `from`'s structured Summary (files w/ +/−, turns with requests
        // and outcomes, tests run) plus "continued from <from>" lineage, then
        // `c.rescueAnswered(from: <new id>, started: true)`. Until then the op emission and
        // the one-line render are live; pressing the button answers "couldn't start" honestly.
        Conversation.rescues = { c, from in
            c.rescueAnswered(from: "not wired yet (item 3)", started: false)
        }
        Conversation.userActivity = { [unowned self] c in if let id = c.sessionID { userActivity(id) } }
        parentOf = { id in Library.shared.parents[id] }
        Conversation.permissionRequests = { [unowned self] c, req in
            guard let id = c.sessionID else { return }
            escalate(req, from: id, name: name(of: c))
        }
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
        guard entry != nil || conv != nil || Self.hasLog(id) else { return nil }
        info.cwd = conv?.status?.cwd ?? entry?.cwd ?? conv?.folder.path
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
            info.degraded = c.status?.degraded ?? []
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
            if let (model, mode, modelCalls, lastEnd, cwd) = tail {
                info.model = info.model ?? model
                info.mode = mode
                info.modelCalls = modelCalls
                info.lastEnd = info.lastEnd ?? lastEnd
                // Where the session actually works now: the last `UseFolder` move or Bash
                // `cd` (into a worktree, say) beats the start cwd from the header.
                if let cwd { info.cwd = cwd }
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

    /// The session's log exists on disk (a session the sidebar's listing doesn't know yet,
    /// or one from another Mac): its log still answers SessionStatus.
    nonisolated private static func hasLog(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: FrogPaths.sessions.appending(path: "\(id).jsonl").path)
    }

    /// The model, mode, model-call count, last turn end and current working folder from a
    /// session's log, without folding the whole history: the last `model_changed` /
    /// `mode_changed`, the summed `turn_ended` usage, the last `turn_ended` reason, and the
    /// last `folder_changed` / `shell_cwd` (else the header's cwd). Nil when the log can't
    /// be read.
    nonisolated private static func logTail(_ id: String) -> (String?, String?, Int, String?, String?)? {
        let file = FrogPaths.sessions.appending(path: "\(id).jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var model: String?
        var mode: String?
        var calls = 0
        var lastEnd: String?
        var cwd: String?
        var headerCwd: String?
        for line in text.split(separator: "\n") {
            guard let v = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if v["type"] as? String == "header" { headerCwd = v["cwd"] as? String }
            guard let env = v["env"] as? [String: Any] else { continue }
            switch env["event"] as? String {
            case "model_changed": model = env["model"] as? String
            case "mode_changed": mode = env["mode"] as? String
            case "folder_changed", "shell_cwd": cwd = env["cwd"] as? String
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
        return (model, mode, calls, lastEnd, cwd ?? headerCwd)
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
        // Worker sessions belong in worktrees: never the user's main checkout unless asked,
        // and never a worktree another engine already runs in.
        if !req.worktree {
            let at = folder
            try await Task.detached { try Self.checkWorkerFolder(at, allowMainCheckout: req.allowMainCheckout) }.value
        }
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
        let c = Conversation(folder: folder, arguments: Self.engineFlags(req: req, parent: parent), model: model)
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
            c.stop(reason: "start timeout (no session id in 20 s)")
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

    /// The permission mode a started session runs in: its parent's by default,
    /// never above it, and yolo only when asked for explicitly.
    static func childMode(asked: String?, parent: Mode?) -> Mode {
        // Modes by how much they allow; a child's mode can't outrank its parent's.
        func rank(_ m: Mode) -> Int { switch m { case .default: 0; case .acceptEdits: 1; case .auto: 2; case .yolo: 3 } }
        let parentMode = parent ?? .default
        if let asked = asked.flatMap(Mode.init(rawValue:)) {
            return rank(asked) <= rank(parentMode) ? asked : parentMode
        }
        // Inherit, except yolo is never passed on silently.
        return parentMode == .yolo ? .auto : parentMode
    }

    /// The engine flags for a session started by another session: its permission
    /// mode (see `childMode`), `--worker` (an agent's session: its shell commands reach only
    /// the `[egress]` allow-list, and the engine keeps that across resumes), plus the
    /// app-wide flags.
    static func engineFlags(req: StartRequest, parent: Conversation?) -> [String] {
        let mode = childMode(asked: req.mode, parent: parent?.status?.mode)
        let flag: [String] = switch mode {
        case .yolo: ["--yolo"]
        case .auto: ["--auto"]
        case .acceptEdits: ["--accept-edits"]
        case .default: []
        }
        return flag + ["--worker"] + Workspace.engineFlags(chat: false).filter { $0 != "--yolo" && $0 != "--auto" && $0 != "--accept-edits" }
    }
}

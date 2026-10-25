import Foundation
import Observation

/// Where a conversation's engine is: a `frog --serve` process on this Mac, or frog on your Mac
/// seen from a phone. The conversation doesn't care which.
@MainActor
protocol ConversationLink: AnyObject {
    /// Every event, then `nil` once when the link ends.
    var onEvent: (Envelope?) -> Void { get set }
    func send(_ op: Op)
    /// Ask it to end (it ends with `nil`).
    func stop()
    /// `stop()`, saying why (the Mac logs it beside the engine's exit).
    func stop(reason: String)
    /// Why it ended on its own, for the transcript.
    var endDescription: String { get }
    /// Whether the engine is still there to send events. A conversation that thinks it's
    /// busy reconciles from the session log when this goes false, so "Working…" never
    /// outlives the engine it was watching.
    var isAlive: Bool { get }
}

extension ConversationLink {
    var isAlive: Bool { true }
    func stop(reason: String) { stop() }
    /// No-op for links without a process of their own (the phone bridge); the Mac's engine
    /// process overrides it.
    func forceKill(reason: String) {}
}

/// What a platform does when things happen in a conversation: sounds, the Mac's sidebar and
/// notifications, the phone's Live Activity. Set once at launch (`Conversation.effects`).
@MainActor
protocol ConversationEffects: AnyObject {
    /// A turn finished, live (not history).
    func turnEnded(_ c: Conversation, turn: TurnState)
    /// Frog asks, live.
    func asked(_ c: Conversation, _ request: PermissionRequest)
    /// You answered (or it stopped waiting).
    func answered(_ c: Conversation, permission id: String)
    /// Running or waiting on you changed.
    func live(_ c: Conversation, running: Bool, waiting: Bool)
}

/// A session: folds its engine's events into turns, and sends it what you do.
@MainActor
@Observable
final class Conversation {
    let folder: URL
    private(set) var sessionID: String?
    private(set) var status: Status?
    private(set) var turns: [TurnState] = []
    private(set) var busy = true
    private(set) var progress: EngineProgress?
    /// The current progress update began. The UI uses this only to describe an in-flight
    /// request and animate its current stage; it never changes the engine's completion count.
    private(set) var progressSince: Date?
    /// A `Present` call's blocks so far, while its arguments stream; gone once its item starts.
    private(set) var presentPreview: Present?
    private(set) var permission: PermissionRequest?
    /// An MCP server waiting on the user.
    private(set) var elicitation: Elicitation?
    /// The model's open `Ask`.
    private(set) var question: Question?
    /// Files dropped anywhere on the conversation, for the composer to attach or mention.
    var dropped: [URL] = []
    /// The terminal and preview panes the engine shares with this session.
    let panes = PaneHub()
    @ObservationIgnored private var appCalls: [String: (JSONValue?, String?) -> Void] = [:]
    private(set) var failure: String?
    /// A reopened session's history is on its way (until the engine's `synced`).
    private(set) var replaying = false
    /// The replay's history ended with a turn still open (another frog process is running
    /// it): once `synced` lands, that turn is running here too, like one started locally.
    @ObservationIgnored private var replayedOpenTurn = false
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
    /// Cloud fallback is important enough to stay visible above the composer for the turn.
    private(set) var fallbackNotice: String?
    /// The context overflowed and compaction failed (the engine's `compaction_failed`): the
    /// session can't go on as it is. True until the rescue op is answered — one line with a
    /// "start a carried-forward session" action until then.
    private(set) var overflowRescue = false
    /// Messages sent while a turn was running; they go out in order as the engine frees up.
    private(set) var queue: [Queued] = []

    /// The user pressed stop on the running turn (cleared when the next one starts), so a
    /// restart can tell a turn they stopped from one a crash or quit cut off.
    private(set) var userStopped = false
    /// The last event's seq, so a reconciliation can ask the log for only what's new.
    @ObservationIgnored private(set) var lastSeq: UInt64 = 0
    /// When the last event arrived; a busy conversation whose engine has gone quiet for this
    /// long reconciles from the session log (see `watchdog`).
    @ObservationIgnored private var lastEventAt = Date.now
    /// Reads a session log's durable events after a seq (the Mac reads `~/.local/share/frog/`
    /// itself; tests feed a fixture). Nil means there's nothing to reconcile from.
    @ObservationIgnored static var logReader: ((String, UInt64) async -> [Envelope])?
    /// Reconciles busy state from the log when the engine is gone.
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Reopened after the app restarted, with the interrupted turn picked back up.
    var resumedAfterRestart = false
    /// The turn was suspended by an app update's drain, and this relaunch carries it on
    /// (with the update notice, not the crash one).
    var suspendedByUpdate = false
    /// `continueInterrupted` called before the engine could take it: it goes first.
    @ObservationIgnored private var continuePending = false
    /// The note a pending continue carries (the update note, or none for a crash resume).
    @ObservationIgnored private var continueNote: String?
    /// Messages from other sessions sent to the engine (`deliver`) that no turn has taken yet.
    /// The engine queues them behind whatever it's doing; between a turn's `idle` and the
    /// next delivered turn's `turn_started`, this is the only sign the engine has work.
    @ObservationIgnored private(set) var pendingDeliveries = 0
    /// Background work running in the engine (Monitors, background jobs and Tasks), as its last
    /// `background` event said. It outlives the turn that started it and dies with the engine,
    /// so an engine with any is never let go.
    @ObservationIgnored private(set) var backgroundRunning = 0

    /// Queued messages taken back out (their "x"), for the composer to put back in its field.
    var restored: [Queued] = []

    /// A message sent while a turn was running.
    struct Queued: Equatable {
        var text: String
        var images: [ToolImage] = []

        /// The composer's field and attachments with this message back in them: its text first,
        /// then a blank line and whatever was already typed; its images ahead of the rest.
        func restore(into draft: String, attachments: [ToolImage]) -> (text: String, images: [ToolImage]) {
            let kept = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft
            let text = [self.text, kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (text, images + attachments)
        }
    }

    @ObservationIgnored private(set) var link: ConversationLink?
    @ObservationIgnored private let replayOnStart: Bool
    /// What this platform does when things happen (see `ConversationEffects`).
    @ObservationIgnored static var effects: ConversationEffects?
    /// Carries out the model's session tools (the Mac's `SessionBroker`); answer with
    /// `replySession`. Without one, requests get an error.
    @ObservationIgnored static var sessionRequests: ((Conversation, SessionRequest) -> Void)?
    /// The user sent something in this conversation (session-message rate limits reset).
    @ObservationIgnored static var userActivity: ((Conversation) -> Void)?
    /// A new permission prompt opened (the Mac's `SessionBroker` escalates it to a parent).
    @ObservationIgnored static var permissionRequests: ((Conversation, PermissionRequest) -> Void)?
    /// Counts of live happenings, for haptics and the frog's face.
    private(set) var stepsDone = 0
    private(set) var turnsDone = 0
    /// A turn just finished: the frog is pleased (or sad) for a moment.
    private(set) var justFinished = false
    @ObservationIgnored private var finishedTask: Task<Void, Never>?
    @ObservationIgnored private var sawFirstIdle = false
    /// The engine is being let go of (`stop()` was called).
    @ObservationIgnored private(set) var stopping = false
    /// A memory command (`/remember` …) is waiting for its answer, which arrives as a notice.
    @ObservationIgnored private var awaitingCommand = false
    /// A notice to show once the transcript has loaded.
    @ObservationIgnored private var pendingFlash: (String, Bool)?
    /// Called when the session id changes or a turn ends, so the sidebar can refresh.
    @ObservationIgnored var onSessionChange: (() -> Void)?
    /// The engine exited on its own (not stopped).
    @ObservationIgnored var onExit: (() -> Void)?

    /// A conversation over `link`. `replay`: a session with history, which the link replays on
    /// `subscribe` up to a `synced`; until then nothing shows busy and anything sent waits.
    /// `failure`: the link couldn't start.
    init(folder: URL, link: ConversationLink?, replay: Bool, session: String? = nil, failure: String? = nil) {
        self.folder = folder
        openedLive = Date()
        replayOnStart = replay
        sessionID = session
        guard let link else {
            self.failure = failure
            busy = false
            return
        }
        self.link = link
        link.onEvent = { [weak self] env in self?.handle(env) }
        panes.send = { [weak link] op in link?.send(op) }
        if replay {
            // Ask for the history straight away: the engine answers while it's still starting
            // up (connecting MCP servers, loading the model). Nothing is running, so it isn't
            // shown busy meanwhile; anything sent waits for the transcript (see `submit`).
            replaying = true
            busy = false
            link.send(.subscribe(after: 0))
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
        Self.userActivity?(self)
        if busy || replaying {
            queue.append(Queued(text: text, images: images))
            return
        }
        if text.hasPrefix("!") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            turns.append(TurnState(number: nil, input: text, end: .complete, sentAt: .now))
            busy = true
            link?.send(.shell(command))
            return
        }
        if Self.isMemoryCommand(text) {
            // The engine answers these itself: no turn, just a notice.
            turns.append(TurnState(number: nil, input: text, end: .complete, sentAt: .now))
            busy = true
            awaitingCommand = true
            link?.send(.submit(text, images: []))
            return
        }
        turns.append(TurnState(number: nil, input: text, images: images, sentAt: .now))
        busy = true
        link?.send(.submit(text, images: images))
    }

    /// The engine is free: everything queued goes as the next turn, together, in order, each
    /// message its own block (and bubble). A `!command` or memory command can't join a turn,
    /// so one at the front goes alone, and the run of messages before the next one goes after.
    private func flushQueue() {
        guard !queue.isEmpty else { return }
        let head = queue.removeFirst()
        guard Self.joinable(head.text) else { return submit(head.text, images: head.images) }
        var more: [MessagePart] = []
        while let next = queue.first, Self.joinable(next.text) {
            more.append(MessagePart(text: next.text, images: next.images))
            queue.removeFirst()
        }
        guard !more.isEmpty else { return submit(head.text, images: head.images) }
        turns.append(TurnState(number: nil, input: head.text, images: head.images, more: more, sentAt: .now))
        busy = true
        link?.send(.submit(head.text, images: head.images, more: more))
    }

    private static func joinable(_ text: String) -> Bool {
        !text.hasPrefix("!") && !isMemoryCommand(text)
    }

    /// A press on a `Present` actions button: the model gets `send` (or the label) as the
    /// user's next message.
    func act(_ choice: Present.Choice) {
        let text = (choice.send ?? "").isEmpty ? choice.label : choice.send!
        if busy || replaying {
            queue.append(Queued(text: text, images: []))
            return
        }
        turns.append(TurnState(number: nil, input: text, sentAt: .now))
        busy = true
        link?.send(.act(label: choice.label, send: choice.send ?? ""))
    }

    private static func isMemoryCommand(_ text: String) -> Bool {
        let name = text.split(whereSeparator: \.isWhitespace).first ?? ""
        return ["/remember", "/forget", "/memory"].contains(String(name))
    }

    /// Take a queued message back for editing: it leaves the queue and goes back to the
    /// composer (see `restored`), not away.
    func unqueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        restored.append(queue.remove(at: index))
    }

    /// The composer's field and attachments with every taken-back message restored, oldest
    /// first; `restored` is emptied.
    func takeRestored(into draft: String, attachments: [ToolImage]) -> (text: String, images: [ToolImage]) {
        let back = restored
        restored = []
        return back.reversed().reduce((text: draft, images: attachments)) { $1.restore(into: $0.text, attachments: $0.images) }
    }

    func interrupt() {
        userStopped = true
        link?.send(.interrupt)
    }

    /// Nothing queued may start this session's next turn: the engine drops the session
    /// messages in its inbox, and the composer's queued sends go back to the field (taken
    /// back, like their "x", never lost). A stop that should stay stopped, and an archive.
    func clearInbox() {
        pendingDeliveries = 0
        restored.append(contentsOf: queue)
        queue.removeAll()
        continuePending = false
        continueNote = nil
        link?.send(.clearInbox)
    }

    /// What an update drain saw: the engine stopped suspended, it had nothing running, or it
    /// never answered inside the budget (the app force-kills it and the turn resumes as a
    /// crash would).
    enum DrainOutcome: Equatable {
        case suspended
        case idle
        case timeout
    }

    /// Ask the engine to stop at a safe point for an app update. The op is sent, not
    /// awaited — every engine drains in parallel. Follow with `awaitDrain`.
    func sendDrain(deadline: Int64) {
        link?.send(.drain(deadline: deadline))
    }

    /// Wait for a `sendDrain` to land: once the turn ended suspended (`TurnEnded` with
    /// `suspended`, then `Idle`), the engine was already idle, or `seconds` passed. A drain
    /// never looks like a stop: `userStopped` stays false, and the turn ends `suspended`,
    /// never `cancelled`.
    func awaitDrain(within seconds: Double) async -> DrainOutcome {
        guard isLive else { return .timeout }
        if !busy { return .idle }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, link?.isAlive == true {
            try? await Task.sleep(for: .milliseconds(50))
            // The suspended turn's end lands in `turns` like any end; `busy` goes false at
            // the `Idle` after it.
            if !busy { return turns.last?.end == .suspended ? .suspended : .idle }
        }
        return .timeout
    }

    /// Send the drain and wait for it (the one-conversation form; the update flow sends
    /// first to all, then waits on all).
    func drain(within seconds: Double) async -> DrainOutcome {
        sendDrain(deadline: Int64(Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1000))
        return await awaitDrain(within: seconds)
    }

    /// Carry on the turn an app update suspended: its own note, so the model knows it wasn't
    /// its fault or the user's. Same shape as a crash-continue otherwise.
    func continueAfterUpdate() {
        resumedAfterRestart = true
        suspendedByUpdate = true
        if busy || replaying {
            continuePending = true
            continueNote = SUSPENDED_NOTE
            return
        }
        busy = true
        link?.send(.continue(note: SUSPENDED_NOTE))
    }

    /// Have the engine carry on with the turn a restart interrupted, ahead of anything queued.
    func continueInterrupted() {
        resumedAfterRestart = true
        if busy || replaying {
            continuePending = true
            return
        }
        busy = true
        link?.send(.continue())
    }

    /// Send a pending `continueInterrupted`; true if it went (the queue waits for its turn).
    private func flushContinue() -> Bool {
        guard continuePending else { return false }
        continuePending = false
        busy = true
        link?.send(.continue(note: continueNote))
        continueNote = nil
        return true
    }

    /// `note`, with a deny: why, sent back to the agent so it can adjust.
    func answer(_ decision: Decision, note: String? = nil) {
        guard let p = permission else { return }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        link?.send(.permission(id: p.id, decision: decision, note: note?.isEmpty == false ? note : nil))
        permission = nil
        Conversation.effects?.answered(self, permission: p.id)
    }

    /// Answer the open `Ask`: the picked labels and/or the user's own words. Neither dismisses it.
    func answer(question choices: [String], other: String? = nil) {
        guard let q = question else { return }
        let other = other?.trimmingCharacters(in: .whitespacesAndNewlines)
        link?.send(.answer(id: q.id, choices: choices, other: other?.isEmpty == false ? other : nil))
        question = nil
    }

    /// Answer the pending MCP elicitation.
    func elicit(_ action: String, content: JSONValue? = nil) {
        guard let e = elicitation else { return }
        link?.send(.elicit(id: e.id, action: action, content: content))
        elicitation = nil
    }

    /// An MCP App calling a tool on its server; `reply` gets the `CallToolResult` or an error.
    func callAppTool(server: String, tool: String, arguments: JSONValue, reply: @escaping (JSONValue?, String?) -> Void) {
        guard let link else { return reply(nil, "the engine isn't running") }
        let id = UUID().uuidString
        appCalls[id] = reply
        link.send(.appCall(id: id, server: server, tool: tool, arguments: arguments))
    }

    /// Name the session (the engine records it).
    func rename(_ title: String) {
        link?.send(.setTitle(title))
        self.title = title
    }

    /// Stop one subagent; the turn goes on with what it found so far.
    func stopSubagent(_ item: String) {
        link?.send(.stopSubagent(id: item))
        upsert(item) { $0.subagent?.stopping = true }
    }

    func setMode(_ mode: Mode) {
        link?.send(.setMode(mode))
        status?.mode = mode
    }

    func setModel(_ spec: String) {
        link?.send(.setModel(spec))
    }

    func compact() {
        busy = true
        link?.send(.compact(focus: nil))
    }

    /// The rescue for a context that overflowed and couldn't be compacted: start a new
    /// session carried forward from this one. The op goes to the engine (it logs the ask);
    /// the client that knows how to carry forward — the Mac's `SessionBroker`, installed as
    /// `Conversation.rescues` — starts the session with this one's structured summary as its
    /// opening context and answers with `rescueAnswered`.
    func startCarriedForward() {
        guard overflowRescue else { return }
        let id = sessionID ?? ""
        link?.send(.continueSession(from: id, why: "the context overflowed and compaction failed"))
        if let rescue = Self.rescues {
            rescue(self, id)
        } else {
            rescueAnswered(from: "no session host (this build can't start sessions)", started: false)
        }
    }

    /// The broker's answer to the rescue op: the carried-forward session is open (`from` is
    /// its id), or why it couldn't be. One line either way; the old session is done.
    func rescueAnswered(from: String, started: Bool) {
        guard overflowRescue else { return }
        overflowRescue = false
        note(started
             ? "carried forward into a new session (\(from))"
             : "couldn't start a carried-forward session: \(from)", warning: !started)
    }

    /// Carries out a rescue's carried-forward start (the Mac's `SessionBroker`); it answers by
    /// calling `rescueAnswered` on the conversation. Without one, the rescue line stays.
    @ObservationIgnored static var rescues: ((Conversation, String) -> Void)?

    /// Let the engine go. `reason` is logged with its exit (pane closed, background idle…).
    func stop(reason: String = "unspecified") {
        stopping = true
        link?.stop(reason: reason)
    }

    /// The engine exited on its own (a test simulating a dead engine calls this directly;
    /// a live link gets it from the link ending).
    func engineExited(_ why: String) {
        guard failure == nil else { return }
        failure = why
        busy = false
        progress = nil
    }

    /// Answer a `sessionRequest`.
    func replySession(_ id: String, result: JSONValue? = nil, error: String? = nil) {
        link?.send(.sessionReply(id: id, result: result, error: error))
    }

    /// A message from another session: the engine queues it and runs it as a turn.
    func deliver(from: String, name: String, message: String) {
        pendingDeliveries += 1
        link?.send(.deliver(from: from, fromName: name, message: message))
    }

    /// Nothing running, nothing waiting, nothing on its way: the engine has started up, the
    /// history is in, no turn is open, nothing is queued here or in the engine's inbox, no
    /// interrupted turn is waiting to continue, no background work is running in the engine,
    /// and nothing waits on the user. Only then may an engine nobody's looking at be let go
    /// (an `idle` alone isn't enough: one follows every op, the startup, a rename, a mode
    /// change, as well as a turn's end).
    var settled: Bool {
        sawFirstIdle && !replaying && !busy && !continuePending
            && queue.isEmpty && pendingDeliveries == 0 && backgroundRunning == 0
            && (turns.last?.finished ?? true)
            && permission == nil && question == nil && elicitation == nil
    }

    /// Has a running engine (not stopped, not failed).
    var isLive: Bool { link != nil && failure == nil && !stopping }

    /// The engine behind the link is still there. What "Working…" requires: never show it
    /// for a turn whose engine has already exited.
    var engineAlive: Bool { isLive && (link?.isAlive ?? false) }

    /// Send the engine an op directly (a title from the Mac's on-device model, say).
    func send(_ op: Op) {
        link?.send(op)
    }

    /// Force-kill the engine: an app update's drain deadline passed without an ack. Its turn
    /// stays open in the log — the crash shape the resume path picks up. `reason` lands in
    /// the engine log's `exit:` line.
    func forceKillEngine(reason: String) {
        link?.forceKill(reason: reason)
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
        #if DEBUG
        // Observed by SwiftUI: a write off the main thread corrupts its graph (see
        // docs/design/attributegraph-corruption.md). The compiler checks @MainActor; this
        // catches what slips past it (ObjC callbacks, @preconcurrency, unchecked Sendable).
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let env else {
            if !stopping {
                failure = link?.endDescription ?? "The frog engine exited."
                onExit?()
            }
            // Whatever its inbox held, and its background work, went with it.
            pendingDeliveries = 0
            backgroundRunning = 0
            busy = false
            progress = nil
            stopWatchdog()
            return
        }
        lastSeq = max(lastSeq, env.seq)
        lastEventAt = .now
        if sessionID != env.session {
            sessionID = env.session
            panes.sessionDir = URL.homeDirectory
                .appending(path: ".local/share/frog/sessions/\(env.session)")
            onSessionChange?()
        }
        defer { reportLive() }
        switch env.event {
        case .turnStarted(let n, let input, let images, let more):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
                turns[i].startedAt = at
            } else {
                turns.append(TurnState(number: n, input: input, images: images, more: more, startedAt: at))
            }
            panes.currentTurn = n
            // A delivered turn takes every message waiting in the engine's inbox (the first as
            // its input, the rest as `more`).
            if !replaying, input.hasPrefix("<session-message ") {
                pendingDeliveries = max(0, pendingDeliveries - 1 - more.count)
            }
            if !replaying { userStopped = false }
            // A replayed turn ran long ago — unless it's still open, when another frog
            // process is running it and `synced` will show it as busy here too.
            if replaying {
                replayedOpenTurn = true
            } else {
                busy = true
            }
        case .turnEnded(let n, let reason, let usage):
            replayedOpenTurn = false
            if let i = turns.lastIndex(where: { $0.number == n }) {
                for index in turns[i].items.indices { turns[i].items[index].imagePreview = nil }
                turns[i].end = reason
                turns[i].usage = usage
                turns[i].endedAt = Date(timeIntervalSince1970: Double(env.created) / 1000)
                if isNews(env) {
                    turnsDone += 1
                    celebrate()
                    if case .complete = reason { FrogSounds.shared.play(.ribbit) }
                    Conversation.effects?.turnEnded(self, turn: turns[i])
                }
            }
            progress = nil
            presentPreview = nil
            // Replayed turns are old news; the sidebar hears once, when the history is in.
            if !replaying { onSessionChange?() }
        case .itemStarted(let id, let kind):
            presentPreview = nil
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
                case .imagePreview(let image, _, _, _): item.imagePreview = image
                }
            }
            progress = nil
        case .itemCompleted(let id, let item):
            let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
            upsert(id) { state in
                state.imagePreview = nil
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
            if case .toolCall = item, isNews(env) { stepsDone += 1 }
        case .itemsDiscarded(let ids):
            // A retried model call streamed a partial reply before the stream failed; drop it
            // so the re-run starts clean.
            if let i = turns.lastIndex(where: { !$0.finished }) {
                turns[i].items.removeAll { ids.contains($0.id) }
            }
            presentPreview = nil
        case .permissionRequest(let req):
            permission = req
            if isNews(env) {
                FrogSounds.shared.play(.drip)
                Conversation.effects?.asked(self, req)
                Conversation.permissionRequests?(self, req)
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
        case .question(let q):
            question = q
            if isNews(env) { FrogSounds.shared.play(.drip) }
            progress = nil
        case .questionResolved(let id):
            if question?.id == id { question = nil }
        case .toolProgress(let id, let p):
            upsert(id) { $0.progress = p }
        case .autoApproved(let item, let reason):
            upsert(item) { $0.autoReason = reason }
        case .permissionDecision:
            // Bookkeeping for the ask rate; nothing to show.
            break
        case .subagent(let item, let inner):
            upsert(item) { state in
                if state.subagent == nil { state.subagent = SubagentRun() }
                state.subagent?.apply(inner)
            }
            progress = nil
        case .appResult(let id, let result, let error):
            appCalls.removeValue(forKey: id)?(result, error)
        case .progress(let update):
            if progress != update { progressSince = Date() }
            progress = update
        case .presentPreview(let p):
            presentPreview = p
        case .notice(let level, let message):
            // Warnings and command answers belong in the transcript; other info is transient.
            if awaitingCommand {
                awaitingCommand = false
                note(message, warning: level == "warn")
            } else if message.hasPrefix("frog api unavailable (") && message.contains(" — continuing on ") {
                fallbackNotice = message
            } else if level == "warn" { note(message, warning: true) } else { show(message) }
        case .error(let e):
            note(e.description, warning: true)
        case .compactionFailed:
            // The raw provider payload is in the engine log, never here: one line and a way
            // out. The rescue action (the banner's button) sends the op.
            overflowRescue = true
        case .compacted(let before, let after):
            note("Summarized the conversation to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .contextPruned(let n, let before, let after):
            note("Trimmed \(n) old tool result\(n == 1 ? "" : "s") to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .drained:
            // The engine's ack for an update drain (steps done, jobs stopped); the update
            // coordinator reads it through the drain's wait below, nothing to fold here.
            break
        case .status(let s):
            status = s
        case .background(let running):
            backgroundRunning = running
        case .synced:
            replaying = false
            // A turn the history ended in the middle of is running in another frog process:
            // show it working, exactly like a turn started here. The events keep streaming
            // in, and its `turn_ended` clears `busy` like any local one.
            if replayedOpenTurn {
                replayedOpenTurn = false
                busy = true
            }
            if let (text, warning) = pendingFlash {
                note(text, warning: warning)
                pendingFlash = nil
            }
            onSessionChange?()
            // Sent while the history loaded: it goes now (the engine takes it once started).
            if !busy, flushContinue() {
            } else if !busy, !queue.isEmpty {
                flushQueue()
            }
        case .idle:
            if !sawFirstIdle {
                sawFirstIdle = true
                // A reopened conversation's engine finished starting up with a message already
                // waiting for it: that turn is next, so it stays busy. A followed session's
                // follower idles only when no turn is open, or once the worker's turn has
                // ended — either way there's nothing to stay busy for.
                if replayOnStart, busy, turns.last?.finished == false { return }
            }
            busy = false
            awaitingCommand = false
            progress = nil
            permission = nil
            elicitation = nil
            question = nil
            // While the history loads, what's queued waits for it (see `.synced`).
            if !replaying, flushContinue() {
            } else if !replaying, !queue.isEmpty {
                flushQueue()
            }
        case .titled(let t):
            title = t
            onSessionChange?()
        case .folderChanged(let cwd):
            let url = URL(fileURLWithPath: cwd)
            let here = folder.resolvingSymlinksInPath().standardizedFileURL.path
            movedTo = url.resolvingSymlinksInPath().standardizedFileURL.path == here ? nil : url
        case .paneNotice(_, let level, let message):
            note(message, warning: level != "info")
        case .paneOpened, .paneScreen, .paneClosed, .paneRequest, .paneCheckpoint:
            panes.apply(env.event)
        case .sessionRequest(let r):
            if let handler = Self.sessionRequests {
                handler(self, r)
            } else {
                replySession(r.id, error: "This app can't reach other sessions.")
            }
        case .modelChanged, .modeChanged, .unknown:
            break
        }
    }

    /// Tell the sidebar whether this conversation is running or waiting on the user.
    private func reportLive() {
        guard let id = sessionID, !replaying else { return }
        _ = id
        let running = turns.last.map { !$0.finished } ?? false
        Conversation.effects?.live(self, running: running && busy, waiting: permission != nil || elicitation != nil || question != nil)
        // A busy conversation watches its engine: one that's gone (or goes quiet so long it
        // must have died mid-turn) reconciles from the session log, so its window never
        // shows "Working…" for a turn that already ended.
        if busy { startWatchdog() } else { stopWatchdog() }
    }

    /// The step in hand, in the transcript's words ("Reading Sidebar.swift…"), while the last
    /// turn runs; nil when it isn't running or it's waiting on the user. For lists that watch
    /// this conversation without showing it (the sidebar's chief tile, the phone).
    var liveActivity: String? {
        guard busy, let last = turns.last, !last.finished else { return nil }
        guard permission == nil, elicitation == nil, question == nil else { return nil }
        if let current = last.items.last(where: { !$0.done && $0.kind != .message }) {
            if current.needsPermission { return nil }
            if case .tool(let name, _) = current.kind, name == "Task" || name == "Diagram" { return nil }
            return ActivityWords.now(current)
        }
        if let m = last.items.last, m.kind == .message, !m.done, !m.text.isEmpty { return "Writing…" }
        if let p = progress, p.label != "thinking", !p.label.isEmpty {
            let s = p.label.prefix(1).uppercased() + p.label.dropFirst()
            return s.hasSuffix("…") ? String(s) : s + "…"
        }
        return "Thinking…"
    }

    /// `summary` for a turn that finished; nil while one runs, for lists that only speak when
    /// there's something to read.
    static func summaryIfEnded(_ turn: TurnState) -> String? {
        guard turn.finished else { return nil }
        return summary(turn)
    }

    /// Starts the reconciliation watch, if it isn't running.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                guard self.busy, !self.replaying else { return self.stopWatchdog() }
                // Quiet for two minutes with a live engine is a long think (compaction, a slow
                // model): trust it. A dead one, or quiet for half an hour, is on its own.
                let quiet = Date.now.timeIntervalSince(self.lastEventAt)
                if self.link?.isAlive == true && quiet < 120 { continue }
                await self.reconcile()
                return
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Re-derive this conversation's state from the session log: the durable events after the
    /// last one seen, applied as if the engine had sent them (a `turn_ended` clears busy, an
    /// `idle` settles everything). Does nothing when the log can't be read.
    func reconcile() async {
        guard let id = sessionID, let read = Self.logReader else { return }
        let after = lastSeq
        let events = await read(id, after)
        guard !events.isEmpty else {
            // Nothing new was logged. With the engine gone that means the turn it was on
            // never finished: it's over either way.
            if link?.isAlive != true { busy = false; progress = nil }
            return
        }
        Motion.cut { events.forEach { self.ingest($0) } }
        if let last = events.last, case .turnEnded = last.event {
            busy = false
            progress = nil
        }
        reportLive()
    }

    /// One line for a notification: the start of the answer, or how the turn ended.
    static func summary(_ turn: TurnState) -> String {
        switch turn.end {
        case .cancelled: return "Interrupted"
        case .suspended: return "Suspended for app update"
        case .error(let e): return e.description
        case .looping: return "Stopped: the model kept repeating the same tool call"
        case .stepLimit: return "Stopped at the step limit"
        case .blockedOnApproval(let denial): return "Stopped: retried a call that was already denied (\(denial))"
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

    func dismissFallbackNotice() {
        fallbackNotice = nil
    }

    /// Show a one-off notice in the transcript (e.g. after a rewind).
    func flash(_ text: String, warning: Bool = false) {
        pendingFlash = (text, warning)
        if !turns.isEmpty { note(text, warning: warning); pendingFlash = nil }
    }

    func note(_ text: String, warning: Bool) {
        // Before anything's been said there's no turn to attach it to: a status line, not an
        // empty "Worked" group.
        guard !turns.isEmpty else { return show(text) }
        let item = ItemState(id: UUID().uuidString, kind: .notice(warning: warning), text: text, done: true)
        turns[turns.count - 1].items.append(item)
    }
}

extension Conversation {
    /// What the frog's face shows for this conversation.
    var mood: FrogMood {
        if permission != nil || elicitation != nil || question != nil { return .waiting }
        if justFinished {
            if case .error? = turns.last?.end { return .sad }
            return .done
        }
        guard busy else { return .idle }
        guard let last = turns.last?.items.last(where: { if case .notice = $0.kind { false } else { true } }) else {
            return .thinking
        }
        switch last.kind {
        case .tool(let name, _) where !last.done:
            return ["Read", "Grep", "Glob", "CodeMap", "Docs", "WebFetch", "WebSearch", "Recall"].contains(name) ? .reading : .working
        case .message where !last.done: return .working
        default: return .thinking
        }
    }

    fileprivate func celebrate() {
        justFinished = true
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.justFinished = false
        }
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

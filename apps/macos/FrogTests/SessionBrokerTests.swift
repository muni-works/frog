import XCTest
@testable import Frog

/// Sessions messaging sessions: routing, the loop guard, idle notices and worktrees.
@MainActor
final class SessionBrokerTests: XCTestCase {
    private struct Delivery: Equatable {
        var to: String, from: String, name: String, message: String
    }

    private var delivered: [Delivery] = []
    private var limited: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    /// Idle stops the broker scheduled, with their delay; `elapse()` runs them (the grace passes).
    private var scheduled: [(Duration, @MainActor () -> Void)] = []

    private func elapse() {
        let due = scheduled
        scheduled = []
        due.forEach { $0.1() }
    }

    private func broker(_ entries: [SessionBroker.Entry]) -> SessionBroker {
        let b = SessionBroker()
        b.directory = { entries }
        b.reach = { [unowned self] to, from, name, message in
            delivered.append(Delivery(to: to, from: from, name: name, message: message))
            return true
        }
        b.onLimit = { [unowned self] in limited.append($0) }
        b.now = { [unowned self] in clock }
        b.after = { [unowned self] delay, work in scheduled.append((delay, work)) }
        return b
    }

    private let chief = SessionBroker.Entry(id: "chief-0001", name: "Chief of Staff", state: "running")
    private let eng = SessionBroker.Entry(id: "eng-0002", name: "Eng Manager", state: "idle")
    private let ops = SessionBroker.Entry(id: "ops-0003", name: "Ops", state: "idle")

    func testRoutesById() throws {
        let b = broker([chief, eng, ops])
        let e = try b.send(from: chief.id, name: chief.name, to: "eng-0002", message: "hi", notifyWhenIdle: false).get()
        XCTAssertEqual(e.id, eng.id)
        XCTAssertEqual(delivered, [Delivery(to: eng.id, from: chief.id, name: chief.name, message: "hi")])
    }

    /// The no-response opt: an informational send goes to `inform` (read, no turn), never to
    /// `reach`, so nothing sits in the target's inbox; a plain send still delivers.
    func testAnInformationalSendIsReadWithoutATurn() throws {
        let b = broker([chief, eng])
        var informed: [Delivery] = []
        b.inform = { to, from, name, message in
            informed.append(Delivery(to: to, from: from, name: name, message: message))
            return true
        }
        _ = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "received", notifyWhenIdle: true, informational: true).get()
        XCTAssertEqual(informed.map(\.message), ["received"])
        XCTAssertTrue(delivered.isEmpty, "no turn-starting delivery")
        _ = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "is the pod up?", notifyWhenIdle: false).get()
        XCTAssertEqual(delivered.map(\.message), ["is the pod up?"])
        XCTAssertEqual(informed.count, 1)
    }

    /// A dead engine (process gone, stale `.live`) shows as idle: sending restarts it with
    /// `-r`, on the session's stored model and mode, and the message starts its next turn.
    func testSendToADeadEngineRestartsItAndStartsATurn() throws {
        let b = broker([chief, eng])
        b.reach = { [unowned self] to, from, name, message in
            // `reach` only gets called with a live-or-restarted engine: the broker's
            // `conversation(for:)` replaces a dead one before delivering.
            delivered.append(Delivery(to: to, from: from, name: name, message: message))
            return true
        }
        let e = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "revive", notifyWhenIdle: false).get()
        XCTAssertEqual(e.state, "idle")
        XCTAssertEqual(delivered.map(\.message), ["revive"])
    }

    /// A child mid-turn (its engine live, the turn open) is never stopped by the broker's
    /// idle bookkeeping: the cancel-at-birth bug was this path stopping a just-started
    /// session on a transient running:false report.
    @MainActor
    func testObserveDoesNotStopABusyBackgroundChild() throws {
        let b = broker([chief, eng])
        let child = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-child"))
        // The child's first turn: started, not yet ended.
        let start = try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"do the work"}"#.utf8))
        child.ingest(start)
        b.track(child, as: eng.id)
        // The broker sees it run (armed), then a transient running:false report mid-turn:
        // the child stays, engine untouched.
        b.observe(eng.id, running: true, waiting: false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertFalse(child.stopping, "a busy child must not be stopped mid-turn")
        // The turn ends, the engine goes idle (as a real engine always does after a turn):
        // now it can let go.
        let end = try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":2,"session":"eng-0002","created":2,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#.utf8))
        let idle = try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":3,"session":"eng-0002","created":3,"event":"idle"}"#.utf8))
        child.ingest(end)
        child.ingest(idle)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertFalse(child.stopping, "not on the bare idle: only after the grace")
        elapse()
        XCTAssertTrue(child.stopping, "an idle child lets go once the grace has passed")
    }

    // MARK: Mass exit (background engines stopped while they still had work)

    /// A background engine resumed to take a message (`-r`, history replayed on `subscribe`)
    /// emits `idle`s before the delivered turn starts: startup, the `set_client_caps` op. None
    /// of them may stop it, even if the session was armed by its previous engine.
    @MainActor
    func testAJustResumedEngineIsNotStoppedByTheIdlesBeforeItsTurn() throws {
        let b = broker([chief, eng])
        b.idleGrace = .seconds(30)
        // Armed by an earlier engine: seen running, then (in the old code) never disarmed.
        let old = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-resume-old"))
        b.track(old, as: eng.id)
        b.observe(eng.id, running: true, waiting: false)
        // The resumed engine: history comes in, then the message is delivered.
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-resume"), reopened: true)
        b.track(c, as: eng.id)
        try c.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"earlier work"}"#))
        try c.ingest(env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        c.deliver(from: chief.id, name: chief.name, message: "status?")
        b.observe(eng.id, running: false, waiting: false)
        try c.ingest(env(#"{"seq":3,"session":"eng-0002","created":3,"event":"synced","upto":2}"#))
        // Startup idle, then the idle after set_client_caps: the delivered turn hasn't started.
        try c.ingest(env(#"{"seq":4,"session":"eng-0002","created":4,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        try c.ingest(env(#"{"seq":5,"session":"eng-0002","created":5,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(c.pendingDeliveries, 1)
        XCTAssertFalse(c.settled, "a delivered message is on its way")
        elapse()
        XCTAssertFalse(c.stopping, "a just-resumed engine with a message to run is never stopped")
        // The delivered turn runs and ends: now it can go, after the grace.
        try c.ingest(env(#"{"seq":6,"session":"eng-0002","created":6,"event":"turn_started","turn":2,"input":"<session-message from=\"chief-0001\" name=\"Chief of Staff\">\nstatus?\n</session-message>"}"#))
        b.observe(eng.id, running: true, waiting: false)
        XCTAssertEqual(c.pendingDeliveries, 0)
        try c.ingest(env(#"{"seq":7,"session":"eng-0002","created":7,"event":"turn_ended","turn":2,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        try c.ingest(env(#"{"seq":8,"session":"eng-0002","created":8,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertFalse(c.stopping)
        XCTAssertEqual(scheduled.first?.0, .seconds(30))
        elapse()
        XCTAssertTrue(c.stopping, "truly idle after the grace: let go")
    }

    /// The signature in today's logs: turn N ends (`idle`), and the message delivered during
    /// it starts as turn N+1 ~15 ms later. The broker stopped the engine on that `idle` and
    /// turn N+1 ended cancelled ~80 ms in, with 0 model calls. A pending delivery keeps it.
    @MainActor
    func testATurnBoundaryWithADeliveredMessageWaitingIsNotStopped() throws {
        let b = broker([chief, eng])
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-boundary"))
        b.track(c, as: eng.id)
        try c.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"idle"}"#))
        try c.ingest(env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_started","turn":1,"input":"work"}"#))
        b.observe(eng.id, running: true, waiting: false)
        // A message lands mid-turn: the engine queues it behind the turn.
        c.deliver(from: chief.id, name: chief.name, message: "and then this")
        try c.ingest(env(#"{"seq":3,"session":"eng-0002","created":3,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        try c.ingest(env(#"{"seq":4,"session":"eng-0002","created":4,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        elapse()
        XCTAssertFalse(c.stopping, "the queued delivery would be cancelled at birth")
        XCTAssertTrue(scheduled.isEmpty, "nothing scheduled while work is on its way")
    }

    /// A manager arms a Monitor and ends its turn: the monitor lives in the engine, so the
    /// engine must outlast the grace (it was stopped 30 s later, the monitor with it, and its
    /// result went unread). Once the monitor ends, the engine lets go after the grace as usual.
    @MainActor
    func testAnEngineWithALiveMonitorIsNotStoppedUntilItEnds() throws {
        let b = broker([chief, eng])
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-monitor"))
        b.track(c, as: eng.id)
        try c.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"idle"}"#))
        try c.ingest(env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_started","turn":1,"input":"watch the pod"}"#))
        b.observe(eng.id, running: true, waiting: false)
        try c.ingest(env(#"{"seq":3,"session":"eng-0002","created":3,"event":"background_started","id":"mon-1","kind":"monitor","label":"pod status"}"#))
        try c.ingest(env(#"{"seq":4,"session":"eng-0002","created":4,"event":"background","running":1}"#))
        try c.ingest(env(#"{"seq":5,"session":"eng-0002","created":5,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        try c.ingest(env(#"{"seq":6,"session":"eng-0002","created":6,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(c.backgroundRunning, 1)
        XCTAssertFalse(c.settled, "a live monitor is work in flight")
        XCTAssertTrue(scheduled.isEmpty, "no idle stop while the monitor runs")
        elapse()
        XCTAssertFalse(c.stopping, "the monitor would die with the engine")
        // Minutes later, with no turn open, the monitor ends on its own.
        try c.ingest(env(#"{"seq":7,"session":"eng-0002","created":7,"event":"background_done","id":"mon-1","kind":"monitor","status":"matched","summary":""}"#))
        try c.ingest(env(#"{"seq":8,"session":"eng-0002","created":8,"event":"background","running":0}"#))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(c.settled)
        XCTAssertFalse(c.stopping, "not at once: only after the grace")
        XCTAssertEqual(scheduled.count, 1)
        elapse()
        XCTAssertTrue(c.stopping, "nothing left running: let go after the grace")
    }

    /// Mid-turn, a queued `set_title` (RenameSession) or `set_mode` is answered with an `idle`
    /// once the turn ends, and the app may see an `idle` while the turn's still open. Neither
    /// stops the engine; and a stop scheduled before the turn started never fires.
    @MainActor
    func testAnEngineMidTurnIsNotStoppedByTheIdleOfAQueuedSetTitle() throws {
        let b = broker([chief, eng])
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-title"))
        b.track(c, as: eng.id)
        try c.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"idle"}"#))
        try c.ingest(env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_started","turn":1,"input":"work"}"#))
        b.observe(eng.id, running: true, waiting: false)
        try c.ingest(env(#"{"seq":3,"session":"eng-0002","created":3,"event":"titled","title":"renamed"}"#))
        try c.ingest(env(#"{"seq":4,"session":"eng-0002","created":4,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        elapse()
        XCTAssertFalse(c.stopping, "the turn is open")
        // Settled for a moment, then a new turn starts before the grace runs out.
        try c.ingest(env(#"{"seq":5,"session":"eng-0002","created":5,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        try c.ingest(env(#"{"seq":6,"session":"eng-0002","created":6,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(scheduled.count, 1)
        try c.ingest(env(#"{"seq":7,"session":"eng-0002","created":7,"event":"turn_started","turn":2,"input":"more work"}"#))
        b.observe(eng.id, running: true, waiting: false)
        try c.ingest(env(#"{"seq":8,"session":"eng-0002","created":8,"event":"turn_ended","turn":2,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#))
        // The first grace runs out while it's settled again: stale, it doesn't fire.
        let stale = scheduled.removeFirst()
        stale.1()
        XCTAssertFalse(c.stopping, "a stop scheduled before the engine worked again is void")
        try c.ingest(env(#"{"seq":9,"session":"eng-0002","created":9,"event":"idle"}"#))
        b.observe(eng.id, running: false, waiting: false)
        elapse()
        XCTAssertTrue(c.stopping, "settled for a whole grace: let go")
    }

    /// A pane opening a session (the sidebar, a restored window) resumes it with `-r` only: no
    /// `-m` (it was the picker's model, so every resume flipped the session's model) and no
    /// mode flag. A new conversation still gets the chosen model.
    func testPaneResumeCarriesNoModelOrMode() {
        UserDefaults.standard.set("yolo", forKey: "defaultMode")
        defer { UserDefaults.standard.removeObject(forKey: "defaultMode") }
        let resume = Workspace.launch(["-r", "eng-0002", "--wait-lock", "5"], chat: false, model: "vercel/anthropic/claude-opus-5.5")
        XCTAssertNil(resume.model)
        XCTAssertEqual(Array(resume.arguments.prefix(4)), ["-r", "eng-0002", "--wait-lock", "5"])
        XCTAssertFalse(resume.arguments.contains("--yolo"))
        let fresh = Workspace.launch([], chat: false, model: "vercel/anthropic/claude-opus-5.5")
        XCTAssertEqual(fresh.model, "vercel/anthropic/claude-opus-5.5")
        XCTAssertTrue(fresh.arguments.contains("--yolo"), "new conversations start in Settings' mode")
    }

    /// Resuming a closed session passes `-r` and nothing that overrides what it last used.
    func testResumeArgumentsCarryNoModelOrMode() {
        let args = SessionBroker.resumeArguments("eng-0002", chat: false)
        XCTAssertEqual(Array(args.prefix(2)), ["-r", "eng-0002"])
        XCTAssertFalse(args.contains("-m"))
        for flag in ["--yolo", "--auto", "--accept-edits", "--mode"] { XCTAssertFalse(args.contains(flag)) }
    }

    /// An engine that died mid-turn (not live, no `turn_ended`) is detected on its next
    /// report: its open turn is reconciled from the log (the chief's call: reconcile, never
    /// auto-resume), and the parent isn't told it's idle-and-done.
    private func env(_ json: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(json.utf8))
    }

    /// 2h: spawn a child, its engine is killed before the first model call, the broker
    /// respawns it — and the first prompt is still delivered, not lost.
    @MainActor
    func testAChildKilledBeforeItsFirstCallGetsItsPromptOnRespawn() throws {
        let b = broker([chief, eng])
        var replayed: [(String, String)] = []
        b.replayPrompt = { id, prompt in replayed.append((id, prompt)); return true }
        b.firstTurnRan = { _ in false }
        b.recordBirth(eng.id, prompt: "build the lymb package")
        let child = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-birth"))
        try child.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"build the lymb package"}"#))
        b.track(child, as: eng.id)
        b.watchStarted(eng.id, reportTo: chief.id)
        b.observe(eng.id, running: true, waiting: false)
        // Killed before the first model call: no turn_ended, process gone.
        child.engineExited("killed")
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(replayed.map(\.0), [eng.id], "respawned")
        XCTAssertEqual(replayed.map(\.1), ["build the lymb package"], "with its first prompt")
        XCTAssertTrue(delivered.isEmpty, "the parent isn't told it's idle")
        XCTAssertEqual(b.births[eng.id]?.attempts, 1)
    }

    /// The cancel-at-birth signature: turn 1 ends cancelled with 0 model calls, the engine
    /// lives on. The first prompt runs again; once a turn makes a call, the record goes.
    @MainActor
    func testAFirstTurnCancelledAtBirthIsReplayedThenForgotten() throws {
        let b = broker([chief, eng])
        var replayed: [String] = []
        var ran = false
        b.replayPrompt = { _, prompt in replayed.append(prompt); return true }
        b.firstTurnRan = { _ in ran }
        b.recordBirth(eng.id, prompt: "the brief")
        let child = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-birth2"))
        try child.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"the brief"}"#))
        b.track(child, as: eng.id)
        // Still starting: busy, nothing replayed.
        b.targetBusy = { _ in true }
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(replayed.isEmpty)
        // Cancelled at 0 calls and settled: replayed once.
        try child.ingest(env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":{"input_tokens":0,"output_tokens":0,"model_calls":0}}"#))
        try child.ingest(env(#"{"seq":3,"session":"eng-0002","created":3,"event":"idle"}"#))
        b.targetBusy = { _ in false }
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(replayed, ["the brief"])
        // The replay runs a real turn: the record is dropped, nothing more replays.
        ran = true
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertNil(b.births[eng.id])
        XCTAssertEqual(replayed.count, 1)
    }

    /// The first prompt is on disk, so an app restart before turn 1 ran doesn't lose it.
    func testBirthsArePersisted() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "frog-births-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = broker([chief, eng])
        a.birthsURL = url
        a.recordBirth(eng.id, prompt: "persist me")
        let b = SessionBroker()
        b.birthsURL = url
        b.loadBirths()
        XCTAssertEqual(b.births[eng.id]?.prompt, "persist me")
    }

    @MainActor
    func testADeadEngineMidTurnIsReconciledNotReportedIdle() async throws {
        let b = broker([chief, eng])
        let child = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-dead"))
        let start = try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"the brief"}"#.utf8))
        child.ingest(start)
        b.track(child, as: eng.id)
        // A watch is armed (the parent asked to hear when it goes idle).
        _ = b.send(from: chief.id, name: chief.name, to: eng.id, message: "brief", notifyWhenIdle: true)
        delivered.removeAll()
        b.observe(eng.id, running: true, waiting: false)
        // The engine dies mid-turn: no turn_ended, its process gone. The next report
        // (running:false) reconciles the open turn from the log instead of telling the
        // parent it's idle, and nothing restarts on its own.
        child.engineExited("The frog engine exited.")
        let saved = Conversation.logReader
        defer { Conversation.logReader = saved }
        let end = try env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#)
        Conversation.logReader = { [self] id, after in id == eng.id && after < 2 ? [end] : [] }
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(delivered.isEmpty, "no idle notice: the open turn is settled from the log, not finished")
        // The log settles it (the turn ended there); the conversation's next report (as
        // `Library.report` forwards it) finds it idle: now the parent hears, once.
        await settled(child)
        XCTAssertEqual(child.busy, false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(delivered.first?.message.contains("is idle") == true)
    }

    /// Wait for a dead conversation's reconcile (a Task) to apply the log, so the next test
    /// never sees it half-done (it's registered in `Library.shared` until it lets go).
    private func settled(_ c: Conversation) async {
        for _ in 0..<200 where c.turns.last.map({ !$0.finished }) ?? false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(c.turns.last?.finished, true, "the reconcile applied the log's turn_ended")
    }

    /// A dead engine leaves the session "busy" forever: the broker reconciles the open turn
    /// from the log and clears its queued count, so queued messages deliver at the next
    /// start instead of waiting on a turn that will never end. No auto-resume.
    @MainActor
    func testADeadEngineIsReconciledAndQueuedMessagesCleared() async throws {
        let b = broker([chief, eng])
        var replayed: [(String, String)] = []
        b.replayPrompt = { id, prompt in replayed.append((id, prompt)); return true }
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-dead2"))
        try target.ingest(env(#"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"long task"}"#))
        b.track(target, as: eng.id)
        // Queue a message: the broker counts it in the target's inbox.
        _ = b.send(from: chief.id, name: chief.name, to: eng.id, message: "follow-up", notifyWhenIdle: false)
        delivered.removeAll()
        XCTAssertEqual(b.pendingInbound(eng.id), 1)
        // The engine is killed mid-turn; the log says the turn ended.
        target.engineExited("killed")
        let saved = Conversation.logReader
        defer { Conversation.logReader = saved }
        let end = try env(#"{"seq":2,"session":"eng-0002","created":2,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#)
        Conversation.logReader = { [self] id, after in id == eng.id && after < 2 ? [end] : [] }
        b.observe(eng.id, running: false, waiting: false)
        // The queued count clears (messages deliver normally at the next start)…
        XCTAssertEqual(b.pendingInbound(eng.id), 0)
        // …nothing auto-resumes…
        XCTAssertTrue(replayed.isEmpty)
        // …and nothing is delivered while no engine is live.
        XCTAssertTrue(delivered.isEmpty)
        // The open turn settles with the log: not busy any more…
        await settled(target)
        XCTAssertEqual(target.busy, false)
        let info = await b.status(of: eng.id)
        XCTAssertEqual(info?.turnRunning, false)
        XCTAssertEqual(info?.queuedMessages, 0)
        // …so the next message delivers (reaching the session restarts its engine) instead
        // of queueing behind a turn that will never end.
        b.observe(eng.id, running: false, waiting: false)
        guard case .success = b.send(from: chief.id, name: chief.name, to: eng.id, message: "again", notifyWhenIdle: false) else {
            return XCTFail("the reconciled session couldn't be reached")
        }
        XCTAssertEqual(delivered.map(\.message), ["again"])
        XCTAssertTrue(replayed.isEmpty, "still no auto-resume")
    }

    func testRoutesByNameIgnoringCase() throws {
        let b = broker([chief, eng, ops])
        XCTAssertEqual(try b.send(from: chief.id, name: "", to: "eng manager", message: "x", notifyWhenIdle: false).get().id, eng.id)
        XCTAssertEqual(try b.resolve("ops-00").get().id, ops.id)
    }

    /// The spurious idle notice: a target mid-turn (live engine, turn open) or with messages
    /// queued is NOT idle, whatever a replayed report said. The notice goes out only when no
    /// turn is running and nothing is queued.
    func testNoIdleNoticeWhileTheTargetIsMidTurnOrQueued() {
        let b = broker([chief, eng])
        var busy = true
        b.targetBusy = { _ in busy }
        b.currentInput = { [chief] _ in "<session-message from=\"\(chief.id)\" name=\"Chief\">\ndo it\n</session-message>" }
        _ = b.send(from: chief.id, name: "Chief", to: eng.id, message: "do it", notifyWhenIdle: true)
        delivered.removeAll()
        // The watch armed (the target ran the message), then a running:false report arrives
        // while the target is still mid-turn: no notice.
        b.observe(eng.id, running: true, waiting: false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(delivered.isEmpty, "mid-turn is not idle")
        // Messages queued behind the turn: still not idle.
        busy = true
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(delivered.isEmpty, "queued messages mean not idle")
        // The turn really is over and nothing waits: one notice.
        busy = false
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(delivered.count, 1)
    }

    func testUnknownAmbiguousAndSelfAreErrors() {
        var twin = ops
        twin.id = "ops-9999"
        let b = broker([chief, eng, ops, twin])
        guard case .failure(let unknown) = b.send(from: chief.id, name: "", to: "nobody", message: "x", notifyWhenIdle: false) else {
            return XCTFail("unknown target routed")
        }
        XCTAssertTrue(unknown.message.contains("No session"))
        guard case .failure(let ambiguous) = b.resolve("Ops") else { return XCTFail("ambiguous name routed") }
        XCTAssertTrue(ambiguous.message.contains("2 sessions"))
        guard case .failure = b.send(from: chief.id, name: "", to: chief.id, message: "x", notifyWhenIdle: false) else {
            return XCTFail("sent to itself")
        }
        XCTAssertTrue(delivered.isEmpty)
    }

    func testRateLimitStopsLoopsUntilTheUserActs() {
        let b = broker([chief, eng])
        for i in 0..<SessionBroker.rateLimit {
            XCTAssertNoThrow(try b.send(from: chief.id, name: "", to: eng.id, message: "\(i)", notifyWhenIdle: false).get())
        }
        guard case .failure(let e) = b.send(from: chief.id, name: "", to: eng.id, message: "again", notifyWhenIdle: false) else {
            return XCTFail("limit not enforced")
        }
        XCTAssertTrue(e.message.contains("Rate limit"))
        XCTAssertEqual(limited, [chief.id])
        XCTAssertEqual(delivered.count, SessionBroker.rateLimit)
        // Other senders aren't affected.
        XCTAssertNoThrow(try b.send(from: eng.id, name: "", to: chief.id, message: "ok", notifyWhenIdle: false).get())
        // The window slides…
        clock += SessionBroker.rateWindow + 1
        XCTAssertNoThrow(try b.send(from: chief.id, name: "", to: eng.id, message: "later", notifyWhenIdle: false).get())
        // …and user activity resets it.
        for _ in 0..<SessionBroker.rateLimit { _ = b.send(from: chief.id, name: "", to: eng.id, message: "m", notifyWhenIdle: false) }
        b.userActivity(chief.id)
        XCTAssertNoThrow(try b.send(from: chief.id, name: "", to: eng.id, message: "user said go", notifyWhenIdle: false).get())
    }

    func testSendResultSaysQueuedWhileBusyAndDeliveredWhenIdle() {
        // SendMessage is a pure queue: a busy target takes the message without being
        // interrupted; an idle one (or one whose engine is gone) has a turn started for it.
        let b = broker([chief, eng])
        var running = true
        b.directory = { [
            SessionBroker.Entry(id: self.chief.id, name: self.chief.name, state: "running"),
            SessionBroker.Entry(id: self.eng.id, name: self.eng.name, state: running ? "running" : "idle"),
        ] }
        // Busy: the message is queued, nothing is cancelled, the target keeps running.
        let toBusy = b.send(from: chief.id, name: chief.name, to: eng.id, message: "when you get a moment", notifyWhenIdle: false)
        XCTAssertEqual(try toBusy.get().state, "running")
        XCTAssertEqual(delivered.count, 1, "the message still reaches the busy target's engine")
        // Idle: the message starts a turn.
        running = false
        delivered.removeAll()
        let toIdle = b.send(from: chief.id, name: chief.name, to: eng.id, message: "fresh one", notifyWhenIdle: false)
        XCTAssertEqual(try toIdle.get().state, "idle")
        XCTAssertEqual(delivered.count, 1)
    }

    func testIdleNoticeAfterTheTargetRunsTheMessage() {
        let b = broker([chief, eng])
        var input: String?
        b.currentInput = { _ in input }
        _ = b.send(from: chief.id, name: "Chief", to: eng.id, message: "do it", notifyWhenIdle: true)
        delivered.removeAll()
        // Idle before it has started on the message: no notice.
        b.observe(eng.id, running: false, waiting: false)
        // Busy with something else first: still not armed.
        input = "earlier work"
        b.observe(eng.id, running: true, waiting: false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(delivered.isEmpty)
        // Runs the message, waits on the user (not idle), then goes idle: one notice.
        input = "<session-message from=\"\(chief.id)\" name=\"Chief\">\ndo it\n</session-message>"
        b.observe(eng.id, running: true, waiting: false)
        b.observe(eng.id, running: false, waiting: true)
        XCTAssertTrue(delivered.isEmpty)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.to, chief.id)
        XCTAssertEqual(delivered.first?.from, "system")
        XCTAssertTrue(delivered.first?.message.contains("Eng Manager") ?? false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(delivered.count, 1)
    }

    func testAStartedSessionReportsItsLastReplyToItsParent() {
        let b = broker([chief, eng])
        b.currentInput = { _ in "build the thing" }
        b.lastReport = { _ in "Done: built it on branch frog/x (3 commits), tests pass." }
        b.watchStarted(eng.id, reportTo: chief.id)
        b.observe(eng.id, running: true, waiting: false)
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.to, chief.id)
        XCTAssertTrue(delivered.first?.message.contains("Its last reply:") ?? false)
        XCTAssertTrue(delivered.first?.message.contains("frog/x") ?? false)
    }

    func testListingLeavesOutTheCaller() {
        let b = broker([chief, eng])
        XCTAssertEqual(b.list(excluding: chief.id).map(\.id), [eng.id])
        guard case .array(let rows) = SessionBroker.json([eng]) else { return XCTFail() }
        XCTAssertEqual(rows.first?["state"]?.string, "idle")
    }

    /// ListSessions filters: cwd_prefix, state, since and limit, with a default cap of 30 —
    /// never the ~150-row dump of every session in the app.
    func testListSessionsFiltersAndLimit() throws {
        var busy = SessionBroker.Entry(id: "a-0001", name: "alpha", state: "running", cwd: "/repo/sub", modified: 3_000)
        busy.branch = "frog/x"
        let idle = SessionBroker.Entry(id: "b-0002", name: "beta", state: "idle", cwd: "/repo", modified: 1_000)
        var old = SessionBroker.Entry(id: "c-0003", name: "gamma", state: "idle", cwd: "/elsewhere", modified: 500)
        old.ahead = 2
        let entries = [busy, idle, old]

        // No filters: everything, most recent first, capped at 30.
        let none = SessionBroker.ListFilter(input: .object([:]))
        XCTAssertEqual(none.limit, 30)
        XCTAssertEqual(none.apply(to: entries, now: Date()).map(\.id), ["a-0001", "b-0002", "c-0003"])

        // cwd_prefix keeps only sessions under that folder.
        let byCwd = SessionBroker.ListFilter(input: .object(["cwd_prefix": .string("/repo")]))
        XCTAssertEqual(byCwd.apply(to: entries, now: Date()).map(\.id), ["a-0001", "b-0002"])

        // state keeps only that state.
        let byState = SessionBroker.ListFilter(input: .object(["state": .string("idle")]))
        XCTAssertEqual(byState.apply(to: entries, now: Date()).map(\.id), ["b-0002", "c-0003"])

        // since: only activity after that unix time (modified is ms).
        let bySince = SessionBroker.ListFilter(input: .object(["since": .number(2)]))
        XCTAssertEqual(bySince.apply(to: entries, now: Date()).map(\.id), ["a-0001"])

        // limit caps the rows.
        let capped = SessionBroker.ListFilter(input: .object(["limit": .number(1)]))
        XCTAssertEqual(capped.apply(to: entries, now: Date()).map(\.id), ["a-0001"])

        // fields carry branch/ahead/dirty through the JSON.
        guard case .array(let rows) = SessionBroker.json([busy, old], fields: ["branch", "ahead", "dirty"]) else {
            return XCTFail()
        }
        XCTAssertEqual(rows.first?["branch"]?.string, "frog/x")
        XCTAssertEqual(rows.last?["ahead"]?.number, 2)
    }

    /// ArchiveSession / UnarchiveSession: the sidebar's archive (never deletes logs), and
    /// unarchiving resolves names among archived sessions too.
    func testArchiveAndUnarchiveUseTheArchiver() throws {
        let b = broker([chief, eng])
        var archived: [String: Bool] = [:]
        b.archiver = { archived[$0] = $1 }
        b.directoryIncludingArchived = { [self.chief, self.eng] }
        // Archive by name.
        let target = try b.resolve("Eng Manager").get()
        b.archive(target.id, true)
        XCTAssertEqual(archived[target.id], true)
        // An archived session is no longer in the plain directory, but resolves for unarchiving.
        b.directory = { [self.chief] }
        guard case .failure = b.resolve("Eng Manager") else { return XCTFail("archived still listed") }
        let back = try b.resolve("Eng Manager", includeArchived: true).get()
        b.archive(back.id, false)
        XCTAssertEqual(archived[back.id], false)
    }

    /// SessionStatus's single truth: a queued inbound message keeps a session "running"
    /// even when its engine reports idle (bug 2d), and the count drains when it starts.
    func testQueuedInboundKeepsAQueuedSessionRunning() throws {
        let b = broker([chief, eng])
        XCTAssertEqual(b.pendingInbound(eng.id), 0)
        _ = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "one", notifyWhenIdle: false).get()
        _ = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "two", notifyWhenIdle: false).get()
        XCTAssertEqual(b.pendingInbound(eng.id), 2, "both messages queued")
        var info = SessionBroker.StatusInfo()
        info.engineAlive = true
        info.queuedMessages = b.pendingInbound(eng.id)
        XCTAssertEqual(info.state, "running", "queued means running, not idle")
        // The target starts its turn: the inbox drains, and the state follows the turn.
        b.observe(eng.id, running: true, waiting: false)
        XCTAssertEqual(b.pendingInbound(eng.id), 0)
        info.queuedMessages = 0
        info.turnRunning = true
        XCTAssertEqual(info.state, "running")
        b.observe(eng.id, running: false, waiting: false)
        info.turnRunning = false
        XCTAssertEqual(info.state, "idle")
        // A dead engine is "dead", whatever else.
        info.engineAlive = false
        XCTAssertEqual(info.state, "dead")
    }

    /// ReadSession without a live engine reads the session's log: user inputs, assistant
    /// text and tool calls, capped at 400 chars, and kinds filters.
    func testReadSessionReadsTheLogWhenTheEngineIsDead() async throws {
        let id = "readtest-\(UUID().uuidString.prefix(8))"
        let path = FrogPaths.sessions.appending(path: "\(id).jsonl")
        try? FileManager.default.createDirectory(at: FrogPaths.sessions, withIntermediateDirectories: true)
        var jsonl = """
        {"type":"event","env":{"seq":3,"session":"\(id)","created":0,"event":"turn_started","turn":1,"input":"fix the bug"}}
        {"type":"event","env":{"seq":4,"session":"\(id)","created":0,"event":"item_completed","id":"i1","item":{"type":"message","text":"done: fixed it"}}}
        {"type":"event","env":{"seq":5,"session":"\(id)","created":0,"event":"item_completed","id":"i2","item":{"type":"tool_call","name":"Bash","arg":"","input":{},"outcome":"ok","output":"\(String(repeating: "x", count: 500))","display":null}}}
        """
        try jsonl.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let b = broker([])
        b.directory = { [] }
        let text = await SessionBroker.testTranscript(id, lastN: 20, kinds: [], broker: b)
        XCTAssertTrue(text.contains("USER: fix the bug"), text)
        XCTAssertTrue(text.contains("ASSISTANT: done: fixed it"), text)
        XCTAssertTrue(text.contains("TOOL Bash -> ok:"), text)
        // The 500-char result is capped at 400 (plus the 400th char and the ellipsis).
        let toolLine = text.split(separator: "\n").first { $0.hasPrefix("TOOL Bash") }
        XCTAssertNotNil(toolLine)
        XCTAssertLessThanOrEqual(toolLine?.count ?? 999, "TOOL Bash -> ok: ".count + 400 + 1)

        // kinds filter: only tools.
        let toolsOnly = await SessionBroker.testTranscript(id, lastN: 20, kinds: ["tool"], broker: b)
        XCTAssertTrue(toolsOnly.contains("TOOL Bash"))
        XCTAssertFalse(toolsOnly.contains("ASSISTANT:"))
    }
    /// Item 3 (org reliability): a degraded engine status reaches SessionStatus (and the
    /// header badge's words): what's degraded and why, each; nothing when it's healthy.
    func testDegradedStatusReachesSessionStatusAndTheBadge() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-degraded"))
        c.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"eng-0002","created":1,"event":"status","model":"ollama/glm-flash","mode":"auto","cwd":"/tmp","messages":0,"context_tokens":null,"context_window":1,"tool_mode":"text","tier":"weak","tokens_per_sec":null,"todos":[],"degraded":[{"kind":"text_tools","what":"text tool calls","why":"native tool calls failed twice this session"},{"kind":"model","what":"on ollama/glm-flash","why":"this session was on anthropic/claude-opus-5-5; it came back on another model nobody picked"}]}"#.utf8)))
        let degraded = c.status?.degraded ?? []
        XCTAssertEqual(degraded.map(\.kind), ["text_tools", "model"])
        XCTAssertEqual(Degraded.badge(degraded), "text tool calls +1")
        XCTAssertTrue(Degraded.detail(degraded).contains("on ollama/glm-flash: this session was on anthropic/claude-opus-5-5"))

        var info = SessionBroker.StatusInfo()
        info.degraded = degraded
        guard case .object(let o) = info.json, case .array(let rows)? = o["degraded"] else {
            return XCTFail("no degraded in SessionStatus")
        }
        XCTAssertEqual(rows.count, 2)
        guard case .object(let first) = rows[0] else { return XCTFail() }
        XCTAssertEqual(first["what"], .string("text tool calls"))
        XCTAssertEqual(first["why"], .string("native tool calls failed twice this session"))

        // Healthy (or an older engine with no field): no badge, no key.
        XCTAssertNil(Degraded.badge([]))
        guard case .object(let healthy) = SessionBroker.StatusInfo().json else { return XCTFail() }
        XCTAssertNil(healthy["degraded"])
    }

    func testStatusInfoJsonCarriesTheFields() throws {
        var info = SessionBroker.StatusInfo()
        info.engineAlive = true
        info.turnRunning = true
        info.turn = 3
        info.turnSeconds = 42
        info.lastEnd = "complete"
        info.model = "local/qwen3-4b"
        info.mode = "auto"
        info.modelCalls = 7
        info.pendingApprovals = 1
        info.pendingSummary = "Bash cargo test"
        info.queuedMessages = 1
        info.cwd = "/tmp/proj"
        info.branch = "frog/fix-the-parser"
        info.ahead = 2
        info.dirty = 5
        guard case .object(let o) = info.json else { return XCTFail() }
        XCTAssertEqual(o["state"]?.string, "running")
        XCTAssertEqual(o["engine_alive"]?.bool, true)
        XCTAssertEqual(o["turn"]?.number, 3)
        XCTAssertEqual(o["turn_seconds"]?.number, 42)
        XCTAssertEqual(o["model"]?.string, "local/qwen3-4b")
        XCTAssertEqual(o["mode"]?.string, "auto")
        XCTAssertEqual(o["model_calls"]?.number, 7)
        XCTAssertEqual(o["pending_approvals"]?.number, 1)
        XCTAssertEqual(o["pending"]?.string, "Bash cargo test")
        XCTAssertEqual(o["queued_messages"]?.number, 1)
        XCTAssertEqual(o["branch"]?.string, "frog/fix-the-parser")
        XCTAssertEqual(o["ahead"]?.number, 2)
        XCTAssertEqual(o["dirty"]?.number, 5)
        // Waiting outranks running.
        info.waiting = true
        XCTAssertEqual(info.state, "waiting")
    }

    func testWorktreeInATempRepo() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "frog-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try SessionBroker.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        // No remote: the worktree bases on the current branch and says so.
        let (dir, branch, base) = try SessionBroker.makeWorktree(from: repo, name: "Fix the Parser!")
        XCTAssertEqual(branch, "frog/fix-the-parser")
        XCTAssertEqual(base, "main", "no remote: the current branch, named in the result")
        XCTAssertEqual(dir.resolvingSymlinksInPath().path, repo.appending(path: ".frog/worktrees/fix-the-parser").resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "a.txt").path))
        XCTAssertEqual(try SessionBroker.git(["branch", "--show-current"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines), branch)
        // The main checkout doesn't see it as untracked.
        XCTAssertEqual(try SessionBroker.git(["status", "--porcelain"], in: repo), "")
        // The same name again gets its own.
        let (_, second, _) = try SessionBroker.makeWorktree(from: repo, name: "Fix the Parser!")
        XCTAssertEqual(second, "frog/fix-the-parser-2")
    }

    /// Item 2c (org reliability): StartSession without worktree:true refuses the user's main
    /// checkout (the repo that owns .frog/worktrees, from anywhere in it) unless forced,
    /// reuses an existing free worktree as-is, and refuses one another engine holds,
    /// naming the session.
    func testWorkerSessionsStayOutOfTheMainCheckout() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "frog-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appending(path: "src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try SessionBroker.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        // A repo never used for worker worktrees is just a folder.
        XCTAssertEqual(SessionBroker.checkout(of: repo), .plain)
        XCTAssertNoThrow(try SessionBroker.checkWorkerFolder(repo, allowMainCheckout: false))

        let (wt, _, _) = try SessionBroker.makeWorktree(from: repo, name: "worker")
        // Now it owns .frog/worktrees: the root and any folder in it are refused…
        for folder in [repo, repo.appending(path: "src")] {
            XCTAssertThrowsError(try SessionBroker.checkWorkerFolder(folder, allowMainCheckout: false)) { e in
                let m = (e as? SessionBroker.BrokerError)?.message ?? "\(e)"
                XCTAssertTrue(m.contains("main checkout"), m)
                XCTAssertTrue(m.contains("worktree:true"), m)
                XCTAssertTrue(m.contains(".frog/worktrees/worker"), "suggests the worktree to reuse: \(m)")
            }
        }
        // …unless explicitly forced.
        XCTAssertNoThrow(try SessionBroker.checkWorkerFolder(repo, allowMainCheckout: true))

        // An existing worktree is reused as-is.
        guard case .worktree(_, let gitDir) = SessionBroker.checkout(of: wt) else { return XCTFail("not a worktree") }
        XCTAssertNoThrow(try SessionBroker.checkWorkerFolder(wt, allowMainCheckout: false))

        // One another engine holds (its lock, as the engine writes it) is refused by name.
        let lock = gitDir.appending(path: "frog-engine.lock")
        try "eng-0002 4242\n".write(to: lock, atomically: true, encoding: .utf8)
        let fd = open(lock.path, O_RDONLY)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try SessionBroker.checkWorkerFolder(wt, allowMainCheckout: false)) { e in
            let m = (e as? SessionBroker.BrokerError)?.message ?? "\(e)"
            XCTAssertTrue(m.contains("session eng-0002"), m)
        }
        // Its engine gone (the flock with it), the worktree is free again.
        close(fd)
        XCTAssertNoThrow(try SessionBroker.checkWorkerFolder(wt, allowMainCheckout: false))
    }

    /// A worktree bases on the repo's remote default branch (origin/HEAD → origin/main), not
    /// the checkout's current branch, so a session forked from a feature branch doesn't
    /// inherit its half-finished work.
    func testWorktreeBasesOnTheRemoteDefaultBranch() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "frog-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try SessionBroker.git(["init", "-q", "-b", "main"], in: repo)
        try "main\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "main"], in: repo)
        // A feature branch with work the main branch doesn't have.
        try SessionBroker.git(["checkout", "-q", "-b", "feature"], in: repo)
        try "feature-only\n".write(to: repo.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "feature"], in: repo)
        // A remote whose default branch is main (origin/HEAD → origin/main).
        let origin = FileManager.default.temporaryDirectory.appending(path: "frog-broker-origin-\(UUID().uuidString)")
        try SessionBroker.git(["clone", "-q", "--bare", repo.path, origin.path], in: repo)
        // The bare clone's HEAD follows the cloned checkout (feature); point it at main.
        try SessionBroker.git(["symbolic-ref", "HEAD", "refs/heads/main"], in: origin)
        try SessionBroker.git(["remote", "add", "origin", origin.path], in: repo)
        try SessionBroker.git(["push", "-q", "origin", "main"], in: repo)
        try SessionBroker.git(["fetch", "-q", "origin"], in: repo)
        try SessionBroker.git(["remote", "set-head", "origin", "-a"], in: repo)

        let (dir, _, base) = try SessionBroker.makeWorktree(from: repo, name: "from a feature branch")
        // Bases on the remote default, not the checkout's feature branch.
        XCTAssertEqual(try SessionBroker.git(["rev-parse", "main"], in: repo), try SessionBroker.git(["rev-parse", "HEAD"], in: dir),
                       "the worktree starts where main is, not where feature is")
        XCTAssertNotEqual(base, "feature")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "feature.txt").path),
                       "the feature branch's work isn't inherited")
    }

    func testSessionMessageParsing() {
        let m = SessionMessage.parse("<session-message from=\"s1\" name=\"Ops &quot;lead&quot;\">\nship it\n</session-message>")
        XCTAssertEqual(m, SessionMessage(from: "s1", name: "Ops \"lead\"", body: "ship it"))
        XCTAssertNil(SessionMessage.parse("just a prompt"))
    }

    func testAPendingApprovalEscalatesToTheParentWithItsCard() throws {
        let b = broker([chief, eng])
        let parent = chief.id
        b.parentOf = { $0 == "eng-0002" ? parent : nil }
        let line = #"{"seq":1,"session":"eng-0002","created":0,"event":"permission_request","id":"perm-1","item":"t1","name":"Bash","arg":"rm -rf /private/tmp/x","always":"","card":{"agent_reason":"cleaning up my build","trigger":"leaves the sandbox","touches":[{"path":"/private/tmp/x","exists":true,"dir":true,"bytes":2048,"created_here":true}],"risk":"deletes 1 path (2.0 KB) that this session created","recommendation":"allow: cleaning up its own output","prefix":"/private/tmp/x","timeout_secs":600}}"#
        let env = try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
        guard case .permissionRequest(let req) = env.event else { return XCTFail() }
        XCTAssertEqual(req.card?.touches?.first?.createdHere, true)
        XCTAssertTrue(b.escalate(req, from: eng.id, name: eng.name))
        XCTAssertEqual(delivered.count, 1)
        let m = try XCTUnwrap(delivered.first)
        XCTAssertEqual(m.to, chief.id)
        XCTAssertEqual(m.from, "system")
        for part in ["card: perm-1", "command: rm -rf /private/tmp/x", "agent says: cleaning up my build", "made by this session", "recommendation: allow", "10 min"] {
            XCTAssertTrue(m.message.contains(part), "missing \(part): \(m.message)")
        }
        // A session nobody started has no one to escalate to.
        XCTAssertFalse(b.escalate(req, from: chief.id, name: chief.name))
        XCTAssertEqual(delivered.count, 1)
    }

    func testDenyWithANoteEncodes() throws {
        let data = try JSONEncoder().encode(Op.permission(id: "p", decision: .deny, note: "use /private/tmp"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["note"] as? String, "use /private/tmp")
        let prefix = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Op.permission(id: "p", decision: .allowPrefix))) as? [String: Any]
        XCTAssertEqual(prefix?["decision"] as? String, "allow_prefix")
        XCTAssertNil(prefix?["note"])
    }

    func testChildModeInheritsCappedAndNeverSilentYolo() {
        // Inherits the parent's mode.
        XCTAssertEqual(SessionBroker.childMode(asked: nil, parent: .auto), .auto)
        XCTAssertEqual(SessionBroker.childMode(asked: nil, parent: .acceptEdits), .acceptEdits)
        XCTAssertEqual(SessionBroker.childMode(asked: nil, parent: .default), .default)
        // Yolo is never inherited silently: a yolo parent's children start in auto.
        XCTAssertEqual(SessionBroker.childMode(asked: nil, parent: .yolo), .auto)
        // An explicit mode is honored when it's not above the parent's…
        XCTAssertEqual(SessionBroker.childMode(asked: "auto", parent: .auto), .auto)
        XCTAssertEqual(SessionBroker.childMode(asked: "default", parent: .auto), .default)
        XCTAssertEqual(SessionBroker.childMode(asked: "yolo", parent: .yolo), .yolo)
        // …and capped when it is.
        XCTAssertEqual(SessionBroker.childMode(asked: "yolo", parent: .auto), .auto)
        XCTAssertEqual(SessionBroker.childMode(asked: "auto", parent: .default), .default)
        // Unknown strings and a missing parent both fall back safely.
        XCTAssertEqual(SessionBroker.childMode(asked: "nonsense", parent: .auto), .auto)
        XCTAssertEqual(SessionBroker.childMode(asked: nil, parent: nil), .default)
    }

    func testSessionOpsEncode() throws {
        let data = try JSONEncoder().encode(Op.deliver(from: "s1", fromName: "Chief", message: "hi"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["op"] as? String, "deliver")
        XCTAssertEqual(obj?["from_name"] as? String, "Chief")
        let caps = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Op.setClientCaps(panes: true, ask: true, sessions: true))) as? [String: Any]
        XCTAssertEqual(caps?["sessions"] as? Bool, true)
        let line = #"{"seq":1,"session":"a","created":0,"event":"session_request","id":"r1","item":"t1","tool":"ListSessions","input":{}}"#
        let env = try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
        guard case .sessionRequest(let r) = env.event else { return XCTFail() }
        XCTAssertEqual(r.tool, "ListSessions")
    }

    /// SetSessionMode can never raise a child above the caller's own mode, and yolo needs
    /// an explicit flag; SetSessionModel forwards the spec to the target.
    @MainActor
    func testSetSessionModeCeilingAndYoloFlag() throws {
        let b = broker([chief, eng])
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-mode"))
        b.track(target, as: eng.id)
        let sender = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-sender"))
        // Both conversations are booted (a status from the engine).
        let statusLine = { (session: String, mode: String) in
            #"{"seq":1,"session":"\#(session)","created":1,"event":"status","model":"m","mode":"\#(mode)","cwd":"/tmp","messages":0,"context_tokens":null,"context_window":1,"tool_mode":"native","tier":"weak","tokens_per_sec":null,"todos":[]}"#
        }
        sender.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(statusLine(chief.id, "accept-edits").utf8)))
        target.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(statusLine(eng.id, "default").utf8)))

        // Equal or lower mode is allowed.
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("accept-edits")])), from: sender)
        XCTAssertEqual(target.status?.mode, .acceptEdits)

        // Raising above the caller's mode is refused: the target stays where it was.
        b.handle(SessionRequest(id: "r2", item: "t2", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("auto")])), from: sender)
        XCTAssertEqual(target.status?.mode, .acceptEdits, "auto refused: the caller is accept-edits")

        // Even a caller in yolo needs the explicit flag to set yolo.
        sender.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(statusLine(chief.id, "yolo").utf8)))
        b.handle(SessionRequest(id: "r3", item: "t3", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("yolo")])), from: sender)
        XCTAssertEqual(target.status?.mode, .acceptEdits, "yolo refused without the flag")
        b.handle(SessionRequest(id: "r4", item: "t4", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("yolo"), "yolo": .bool(true)])), from: sender)
        XCTAssertEqual(target.status?.mode, .yolo)
    }

    /// StopSession interrupts a busy target's running turn (Op.interrupt applies
    /// immediately, unlike SendMessage which only queues); an idle one gets "nothing to
    /// stop", and the caller itself is refused.
    @MainActor
    func testStopSessionInterruptsABusyTarget() throws {
        let b = broker([chief, eng])
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-stop"))
        // A turn is open, so the target reads busy.
        let start = try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"eng-0002","created":1,"event":"turn_started","turn":1,"input":"long task"}"#.utf8))
        target.ingest(start)
        b.track(target, as: eng.id)
        let chiefConv = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-chief"))

        // Busy: the interrupt is sent (a preview conversation records it as userStopped).
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "StopSession", input: .object(["id": .string(eng.id)])), from: chiefConv)
        XCTAssertTrue(target.userStopped, "a running target is interrupted")

        // Idle: a fresh conversation with no turn open is not interrupted.
        let idleTarget = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-idle"))
        b.track(idleTarget, as: ops.id)
        b.handle(SessionRequest(id: "r2", item: "t2", tool: "StopSession", input: .object(["id": .string(ops.id)])), from: chiefConv)
        XCTAssertFalse(idleTarget.userStopped, "an idle target is not interrupted")

        // Stopping yourself is refused.
        b.handle(SessionRequest(id: "r3", item: "t3", tool: "StopSession", input: .object(["id": .string(chief.id)])), from: chiefConv)
    }

    /// Item 2b (org reliability): StopSession with `clear_queue` leaves zero queued messages
    /// (the engine's inbox, the broker's count and its re-send list), so nothing queued
    /// restarts the stopped session. Without the flag the queue stays, as before.
    @MainActor
    func testStopSessionWithClearQueueLeavesNothingQueued() throws {
        let b = broker([chief, eng, ops])
        let chiefConv = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-chief"))
        let busyTurn = { (id: String) in
            try JSONDecoder.frog.decode(Envelope.self, from: Data(
                #"{"seq":1,"session":"\#(id)","created":1,"event":"turn_started","turn":1,"input":"long task"}"#.utf8))
        }
        var targets: [String: Conversation] = [:]
        for id in [eng.id, ops.id] {
            let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-\(id)"))
            targets[id] = target
            target.ingest(try busyTurn(id))
            b.track(target, as: id)
            for m in ["one", "two"] {
                _ = try b.send(from: chief.id, name: chief.name, to: id, message: m, notifyWhenIdle: false).get()
                // What the real `reach` does: the engine gets it, behind the running turn.
                target.deliver(from: chief.id, name: chief.name, message: m)
            }
            XCTAssertEqual(b.pendingInbound(id), 2)
            XCTAssertEqual(target.pendingDeliveries, 2)
        }
        let target = targets[eng.id]!
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "StopSession",
                                input: .object(["id": .string(eng.id), "clear_queue": .bool(true)])), from: chiefConv)
        XCTAssertTrue(target.userStopped)
        XCTAssertEqual(b.pendingInbound(eng.id), 0, "nothing queued after a clearing stop")
        XCTAssertEqual(target.pendingDeliveries, 0, "the engine's inbox was cleared")

        // A plain stop keeps the queue: the next message runs, as documented.
        let other = targets[ops.id]!
        b.handle(SessionRequest(id: "r2", item: "t2", tool: "StopSession",
                                input: .object(["id": .string(ops.id)])), from: chiefConv)
        XCTAssertTrue(other.userStopped)
        XCTAssertEqual(b.pendingInbound(ops.id), 2)
        XCTAssertEqual(other.pendingDeliveries, 2)
    }

    /// Item 2b: archiving cancels what's queued for the session — inbox, re-send list and a
    /// first prompt waiting to be replayed — so nothing starts an archived session again.
    @MainActor
    func testArchiveSessionCancelsItsQueuedMessages() throws {
        let b = broker([chief, eng])
        var archived: [String: Bool] = [:]
        b.archiver = { archived[$0] = $1 }
        let chiefConv = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-chief"))
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-archive"))
        b.track(target, as: eng.id)
        b.recordBirth(eng.id, prompt: "the first prompt")
        _ = try b.send(from: chief.id, name: chief.name, to: eng.id, message: "queued", notifyWhenIdle: false).get()
        target.deliver(from: chief.id, name: chief.name, message: "queued")
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "ArchiveSession",
                                input: .object(["id": .string(eng.id)])), from: chiefConv)
        XCTAssertEqual(archived[eng.id], true)
        XCTAssertEqual(b.pendingInbound(eng.id), 0)
        XCTAssertEqual(target.pendingDeliveries, 0)
        XCTAssertNil(b.births[eng.id], "an archived session's first prompt is never replayed")
    }

    /// ListApprovals collects the pending permission cards across sessions (read-only,
    /// with age) and clears their age once they stop waiting.
    @MainActor
    func testListApprovalsCollectsPendingCards() throws {
        let b = broker([chief, eng])
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-approval"))
        b.track(target, as: eng.id)
        // A permission card arrives on the target.
        target.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"eng-0002","created":1,"event":"permission_request","id":"p1","item":"t1","name":"Bash","arg":"cargo build","always":"Allow cargo","preview":null,"reason":"leaves the sandbox"}"#.utf8)))
        b.observe(eng.id, running: true, waiting: true)
        clock += 30
        // The card is there to see, with its age.
        XCTAssertEqual(b.approvalsForTesting.count, 1)
        let row = b.approvalsForTesting.first
        XCTAssertEqual(row?.command, "cargo build")
        XCTAssertEqual(row?.tool, "Bash")
        XCTAssertEqual((row?.ageSeconds ?? 0) >= 30, true)
        // The user answers the card: it's resolved, the age tracking clears, nothing lists.
        target.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":2,"session":"eng-0002","created":2,"event":"permission_resolved","id":"p1","decision":"allow"}"#.utf8)))
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(b.approvalsForTesting.isEmpty)
        XCTAssertNil(b.waitingSinceForTesting[eng.id])
    }

    /// RenameSession renames an open conversation through its engine (the sidebar's own
    /// path: Op.setTitle, then the sidebar refreshes).
    @MainActor
    func testRenameSessionSetsTheTitle() async throws {
        let b = broker([chief, eng])
        b.directoryIncludingArchived = { [self.chief, self.eng] }
        let target = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-rename"))
        b.track(target, as: eng.id)
        let probe = Conversation(preview: URL(fileURLWithPath: "/tmp/demo-probe"))
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "RenameSession",
                                input: .object(["id": .string(eng.id), "title": .string("engine room")])), from: probe)
        XCTAssertEqual(target.title, "engine room")
        // An empty title is refused.
        b.handle(SessionRequest(id: "r2", item: "t2", tool: "RenameSession",
                                input: .object(["id": .string(eng.id), "title": .string("  ")])), from: probe)
    }

    /// SetSessionMode / SetSessionModel with no engine running: persisted (not refused), said
    /// so in the reply, and applied by the next engine start — the model as its `-m`, the
    /// mode as the op it takes at its first boundary — once, then forgotten. The mode
    /// ceiling holds for a stopped target too.
    @MainActor
    func testSetSessionModeAndModelPersistWhenNoEngineRunsAndApplyAtNextStart() throws {
        let b = broker([chief, eng])
        let link = QueueLink()
        let sender = Conversation(folder: URL(fileURLWithPath: "/tmp/demo-persist"), link: link, replay: false)
        let status = { (mode: String) in
            #"{"seq":1,"session":"chief-0001","created":1,"event":"status","model":"m","mode":"\#(mode)","cwd":"/tmp","messages":0,"context_tokens":null,"context_window":1,"tool_mode":"native","tier":"weak","tokens_per_sec":null,"todos":[]}"#
        }
        let clear = {
            UserDefaults.standard.removeObject(forKey: "sessionModels")
            UserDefaults.standard.removeObject(forKey: "sessionModes")
        }
        clear()
        defer { clear() }
        let replies = { link.sent.filter { $0["op"] as? String == "session_reply" } }

        // The ceiling holds while stopped: an accept-edits caller can't store auto.
        sender.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(status("accept-edits").utf8)))
        b.handle(SessionRequest(id: "r0", item: "t0", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("auto")])), from: sender)
        XCTAssertNil(Library.shared.storedMode(eng.id), "a refused mode isn't stored")
        XCTAssertNotNil(replies().last?["error"])

        // Within the ceiling: both persist, and the replies say so.
        sender.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(status("yolo").utf8)))
        b.handle(SessionRequest(id: "r1", item: "t1", tool: "SetSessionMode",
                                input: .object(["id": .string(eng.id), "mode": .string("auto")])), from: sender)
        b.handle(SessionRequest(id: "r2", item: "t2", tool: "SetSessionModel",
                                input: .object(["id": .string(eng.id), "model": .string("local/qwen3-4b")])), from: sender)
        let texts = replies().suffix(2).compactMap { $0["result"] as? String }
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts.allSatisfy { $0.contains("persisted (applies next start)") }, "\(texts)")

        // The next start takes them: the model for `-m`, the mode sent to the fresh engine.
        let stored = Library.shared.takeStored(eng.id)
        XCTAssertEqual(stored.model, "local/qwen3-4b")
        XCTAssertEqual(stored.mode, .auto)
        let engine = QueueLink()
        let started = Conversation(folder: URL(fileURLWithPath: "/tmp/demo-started"), link: engine, replay: true, session: eng.id)
        SessionBroker.apply(stored, to: started)
        XCTAssertTrue(engine.sent.contains { $0["op"] as? String == "set_mode" && $0["mode"] as? String == "auto" })
        // Once: the engine's log remembers from here, so a later restart doesn't re-apply.
        let again = Library.shared.takeStored(eng.id)
        XCTAssertNil(again.model)
        XCTAssertNil(again.mode)
    }

    /// A dead session's SessionStatus reports the ACTIVE worktree: the header says the repo
    /// root, a Bash `cd` (logged as `shell_cwd`) moved into a worktree, and the status —
    /// cwd, branch, ahead, dirty — follows the worktree, not the root.
    func testStatusReportsTheActiveWorktreeFromTheLog() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "frog-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try SessionBroker.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        let (tree, branch, _) = try SessionBroker.makeWorktree(from: repo, name: "active tree")
        // One uncommitted file in the worktree, none in the root.
        try "wip\n".write(to: tree.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let id = "cwdtest-\(UUID().uuidString.prefix(8))"
        let path = FrogPaths.sessions.appending(path: "\(id).jsonl")
        try? FileManager.default.createDirectory(at: FrogPaths.sessions, withIntermediateDirectories: true)
        let jsonl = """
        {"type":"header","version":1,"id":"\(id)","cwd":"\(repo.path)","model":"m","created":0}
        {"type":"event","env":{"seq":2,"session":"\(id)","created":0,"event":"shell_cwd","cwd":"\(tree.path)"}}
        {"type":"event","env":{"seq":3,"session":"\(id)","created":0,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}}
        """
        try jsonl.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let b = broker([])
        let info = await b.status(of: id)
        XCTAssertEqual(info?.cwd, tree.path, "the worktree the shell moved into, not the header's root")
        XCTAssertEqual(info?.branch, branch)
        XCTAssertEqual(info?.dirty, 1)
        XCTAssertNil(info?.ahead, "no upstream: ahead is unknown, not 0")
        XCTAssertEqual(info?.state, "dead")
    }

    /// With no move logged, the header's cwd answers (a log-only session still has a folder).
    func testStatusFallsBackToTheHeaderCwd() async throws {
        let id = "cwdtest-\(UUID().uuidString.prefix(8))"
        let path = FrogPaths.sessions.appending(path: "\(id).jsonl")
        try? FileManager.default.createDirectory(at: FrogPaths.sessions, withIntermediateDirectories: true)
        try """
        {"type":"header","version":1,"id":"\(id)","cwd":"/tmp/start-here","model":"m","created":0}
        """.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let info = await broker([]).status(of: id)
        XCTAssertEqual(info?.cwd, "/tmp/start-here")
    }
}

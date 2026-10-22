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

    private func broker(_ entries: [SessionBroker.Entry]) -> SessionBroker {
        let b = SessionBroker()
        b.directory = { entries }
        b.reach = { [unowned self] to, from, name, message in
            delivered.append(Delivery(to: to, from: from, name: name, message: message))
            return true
        }
        b.onLimit = { [unowned self] in limited.append($0) }
        b.now = { [unowned self] in clock }
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
        XCTAssertTrue(child.stopping, "an idle child lets go")
    }

    /// An engine that died mid-turn (not live, no `turn_ended`) is detected on its next
    /// report and its turn restarted, not reported idle-and-done.
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
    func testADeadEngineMidTurnIsRestartedNotReportedIdle() throws {
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
        // (running:false) must restart the turn instead of telling the parent it's idle.
        child.engineExited("The frog engine exited.")
        b.observe(eng.id, running: false, waiting: false)
        XCTAssertTrue(delivered.isEmpty, "no idle notice: the turn is picked back up, not finished")
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
}

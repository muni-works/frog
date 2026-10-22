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
        try SessionBroker.git(["init", "-q"], in: repo)
        try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        let (dir, branch) = try SessionBroker.makeWorktree(from: repo, name: "Fix the Parser!")
        XCTAssertEqual(branch, "frog/fix-the-parser")
        XCTAssertEqual(dir.resolvingSymlinksInPath().path, repo.appending(path: ".frog/worktrees/fix-the-parser").resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "a.txt").path))
        XCTAssertEqual(try SessionBroker.git(["branch", "--show-current"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines), branch)
        // The main checkout doesn't see it as untracked.
        XCTAssertEqual(try SessionBroker.git(["status", "--porcelain"], in: repo), "")
        // The same name again gets its own.
        let (_, second) = try SessionBroker.makeWorktree(from: repo, name: "Fix the Parser!")
        XCTAssertEqual(second, "frog/fix-the-parser-2")
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

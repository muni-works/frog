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
}

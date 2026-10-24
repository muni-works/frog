import XCTest
@testable import Frog

/// The open-session registry, and what a relaunch does with each saved session.
@MainActor
final class SessionRegistryTests: XCTestCase {
    private func session(_ id: String, running: Bool, stopped: Bool = false) -> OpenSession {
        OpenSession(id: id, cwd: "/tmp/demo", model: "anthropic/claude", window: 0, pane: 0,
                    turnRunning: running, userStopped: stopped, queued: [])
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "frog-registry-\(UUID().uuidString)/open-sessions.json")
        var s = OpenSessions()
        s.sessions = [
            OpenSession(id: "a", cwd: "/tmp/a", model: "m", window: 0, pane: 0, turnRunning: true,
                        userStopped: false, queued: ["then run the tests", "and commit"]),
            OpenSession(id: "b", cwd: "/tmp/b", model: nil, window: 1, pane: 2, turnRunning: false),
        ]
        s.quit = .resume
        s.noAutoContinue = ["b"]
        SessionRegistry.save(s, to: url)
        XCTAssertEqual(SessionRegistry.load(url), s)
        // Rewritten in place, atomically: the new contents, no leftovers.
        s.sessions.removeLast()
        SessionRegistry.save(s, to: url)
        XCTAssertEqual(SessionRegistry.load(url), s)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["open-sessions.json"])
    }

    func testMissingOrCorruptFileLoadsAsNothing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "frog-registry-\(UUID().uuidString).json")
        XCTAssertNil(SessionRegistry.load(url))
        try Data("{\"sessions\": [".utf8).write(to: url)
        XCTAssertNil(SessionRegistry.load(url))
    }

    func testRestoreDecisions() {
        func action(quit: OpenSessions.Quit?, _ s: OpenSession, optOut: Bool = false) -> RestoreAction {
            var r = OpenSessions()
            r.quit = quit
            r.sessions = [s]
            if optOut { r.noAutoContinue = [s.id] }
            return r.action(for: s)
        }
        let running = session("s", running: true)
        let stopped = session("s", running: true, stopped: true)
        let idle = session("s", running: false)

        // Crash (no quit recorded): a running turn carries on.
        XCTAssertEqual(action(quit: nil, running), .continue)
        // Quit, choosing to resume: carries on.
        XCTAssertEqual(action(quit: .resume, running), .continue)
        // Quit, letting turns go: just reopens.
        XCTAssertEqual(action(quit: .discard, running), .reopen)
        // The user stopped it: never restarted behind their back, crash or quit.
        XCTAssertEqual(action(quit: nil, stopped), .reopen)
        XCTAssertEqual(action(quit: .resume, stopped), .reopen)
        // Nothing was running.
        XCTAssertEqual(action(quit: nil, idle), .reopen)
        XCTAssertEqual(action(quit: .resume, idle), .reopen)
        // Opted out in the banner.
        XCTAssertEqual(action(quit: nil, running, optOut: true), .reopen)
    }

    /// `continue` goes to the engine ahead of messages queued before the restart.
    func testContinueGoesBeforeQueuedMessages() throws {
        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: true, session: "s")
        c.continueInterrupted()
        c.submit("and then this")
        XCTAssertTrue(c.resumedAfterRestart)
        XCTAssertEqual(link.ops, ["subscribe"], "both wait for the history")
        link.onEvent(try envelope(#""event":"synced","upto":0"#))
        XCTAssertEqual(link.ops, ["subscribe", "continue"])
        link.onEvent(try envelope(#""event":"idle""#))
        link.onEvent(try envelope(#""event":"turn_started","turn":1,"input":"x""#))
        link.onEvent(try envelope(#""event":"idle""#))
        XCTAssertEqual(link.ops, ["subscribe", "continue", "submit"])
    }

    func testStopMarksTheTurnUserStopped() {
        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false)
        XCTAssertFalse(c.userStopped)
        c.interrupt()
        XCTAssertTrue(c.userStopped)
    }


    // MARK: Graceful restart

    /// The update manifest: `afterUpdate` + `suspendedByUpdate` round-trip, and the restore
    /// action a suspended session gets.
    func testUpdateManifestRoundTripAndActions() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "frog-registry-\(UUID().uuidString)/open-sessions.json")
        var s = OpenSessions()
        s.sessions = [
            OpenSession(id: "a", cwd: "/tmp/a", model: "m", window: 0, pane: 0, turnRunning: true,
                        suspendedByUpdate: true),
            OpenSession(id: "b", cwd: "/tmp/b", model: "m", window: 0, pane: 1, turnRunning: false),
        ]
        s.quit = .resume
        s.afterUpdate = true
        SessionRegistry.save(s, to: url)
        XCTAssertEqual(SessionRegistry.load(url), s, "suspendedByUpdate survives the write")
        XCTAssertEqual(s.action(for: s.sessions[0]), .continue, "a suspended turn carries on")
        XCTAssertEqual(s.action(for: s.sessions[1]), .reopen, "an idle session just reopens")
    }

    /// A drained session continues with the update note, never the crash default: the op
    /// the engine sees carries the update wording.
    func testContinueAfterUpdateSendsTheUpdateNote() throws {
        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: true, session: "s")
        c.continueAfterUpdate()
        XCTAssertTrue(c.resumedAfterRestart)
        XCTAssertTrue(c.suspendedByUpdate)
        link.onEvent(try envelope(#""event":"synced","upto":0"#))
        link.onEvent(try envelope(#""event":"idle""#))
        XCTAssertEqual(link.ops, ["subscribe", "continue"])
        // The note rides on the continue op (the engine turns it into the turn's input).
        let data = try JSONEncoder().encode(Op.continue(note: SUSPENDED_NOTE))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let note = try XCTUnwrap(obj["note"] as? String)
        XCTAssertTrue(note.contains("resumed after the app updated"), note)
        XCTAssertFalse(note.contains("interrupted"), "never the crash wording")
    }

    /// The drain op encodes with its unix-ms deadline; the interrupted turn is never
    /// marked user-stopped.
    func testDrainOpEncodesDeadlineAndIsNeverAStop() {
        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false)
        c.sendDrain(deadline: 1_700_000_000_000)
        XCTAssertEqual(link.ops, ["drain"])
        XCTAssertFalse(c.userStopped)
        let data = try? JSONEncoder().encode(Op.drain(deadline: 1_700_000_000_000))
        let obj = (try? JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        XCTAssertEqual(obj?["deadline"] as? Int64, 1_700_000_000_000)
    }
    private var seq: UInt64 = 0

    private func envelope(_ body: String) throws -> Envelope {
        seq += 1
        return try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }
}

@MainActor
private final class RecordingLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var ops: [String] = []
    func send(_ op: Op) {
        guard let data = try? JSONEncoder().encode(op),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["op"] as? String else { return }
        ops.append(name)
    }
    func stop() {}
    var endDescription: String { "" }
}

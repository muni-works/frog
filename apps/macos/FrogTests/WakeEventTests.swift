import XCTest
@testable import Frog

/// Background wakes are events, not something the user said: the `background_*` events decode
/// (they used to fall through to `.unknown`), and a turn the engine started on a wake opens
/// with event rows, never a user bubble.
final class WakeEventTests: XCTestCase {
    private func decode(_ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"s","created":0,\#(body)}"#.utf8))
    }

    func testBackgroundEventsDecode() throws {
        let started = try decode(#""event":"background_started","id":"job-3","kind":"job","label":"sleep 570; wc -l out","log":"/tmp/s.jobs/job-3.log""#)
        guard case .backgroundStarted("job-3", "job", "sleep 570; wc -l out", let log) = started.event else {
            return XCTFail("\(started.event)")
        }
        XCTAssertEqual(log, "/tmp/s.jobs/job-3.log")
        // Monitors and timers have no log file; an older engine sends none either.
        let timer = try decode(#""event":"background_started","id":"mon-1","kind":"timer","label":"wake in 60s""#)
        guard case .backgroundStarted("mon-1", "timer", "wake in 60s", nil) = timer.event else {
            return XCTFail("\(timer.event)")
        }
        let progress = try decode(#""event":"background_progress","id":"job-3","text":"26""#)
        guard case .backgroundProgress("job-3", "26") = progress.event else { return XCTFail("\(progress.event)") }
        let done = try decode(#""event":"background_done","id":"mon-1","kind":"monitor","status":"matched","summary":"<monitor-done id=mon-1 status=matched polls=1>\nexit=0\n</monitor-done>""#)
        guard case .backgroundDone("mon-1", "monitor", "matched", let summary) = done.event else {
            return XCTFail("\(done.event)")
        }
        XCTAssertTrue(summary.hasPrefix("<monitor-done id=mon-1"))
        // A stop has an empty summary.
        let stopped = try decode(#""event":"background_done","id":"job-2","kind":"job","status":"stopped","summary":"""#)
        guard case .backgroundDone("job-2", "job", "stopped", "") = stopped.event else { return XCTFail("\(stopped.event)") }
    }

    func testWakesParseInOrderWithTheirOutcomes() throws {
        // The specimen's wake turn, and a joined pair as the engine sends several at once.
        let input = "<monitor-done id=mon-1 status=timeout polls=7>\nno match after 590s. Last output:\n      23\n</monitor-done>\n\n<job-done id=job-8 exit=0>\ndone cad-031 (32)\n</job-done>\n\n<wakeup id=mon-9 after_s=60>check the deploy</wakeup>"
        let wakes = try XCTUnwrap(WakeEvent.parse(input))
        XCTAssertEqual(wakes.map(\.kind), [.monitor, .job, .timer])
        XCTAssertEqual(wakes.map(\.id), ["mon-1", "job-8", "mon-9"])
        XCTAssertEqual(wakes.map(\.outcome), ["timed out", "exit 0", "after 60s"])
        XCTAssertEqual(wakes[0].failed, true)
        XCTAssertEqual(wakes[1].body, "done cad-031 (32)")
        XCTAssertEqual(wakes[2].body, "check the deploy")
        let failed = try XCTUnwrap(WakeEvent.parse("<job-done id=job-2 exit=1>\nboom\n</job-done>"))
        XCTAssertEqual(failed.first?.outcome, "failed (exit 1)")
        let task = try XCTUnwrap(WakeEvent.parse("<task-done id=task-1>\nreport\n</task-done>"))
        XCTAssertEqual(task.first?.kind, .task)
        // A plain notice beside a wake (a job an app update stopped) is a note row.
        let mixed = try XCTUnwrap(WakeEvent.parse("Background job job-4 was interrupted by the app update.\n\n<wakeup id=mon-5 after_s=5></wakeup>"))
        XCTAssertEqual(mixed.map(\.kind), [.note, .timer])
        // What a person typed is not a wake, even when it mentions one.
        XCTAssertNil(WakeEvent.parse("why did <job-done id=job-1 exit=0> fail?"))
        XCTAssertNil(WakeEvent.parse("fix the build"))
        XCTAssertNil(WakeEvent.parse(""))
    }

    /// The bug: a monitor-done turn rendered as a user bubble. It leads with event rows.
    func testAWakeTurnLeadsWithEventRowsNotAUserBubble() {
        let wake = TurnState(number: 13, input: "<monitor-done id=mon-1 status=timeout polls=7>\nno match after 590s.\n</monitor-done>")
        guard case .wakes(let rows) = TurnLead(wake) else { return XCTFail("\(TurnLead(wake))") }
        XCTAssertEqual(rows.map(\.id), ["mon-1"])
        XCTAssertEqual(TurnLead(TurnState(number: 1, input: "fix the build")), .prompt)
        guard case .sessionMessage = TurnLead(TurnState(number: 2, input: "<session-message from=\"s1\" name=\"Chief\">\ngo\n</session-message>")) else {
            return XCTFail("a session message is its card")
        }
        XCTAssertEqual(TurnLead(TurnState(number: 3, input: "")), TurnLead.none)
    }

    /// The conversation keeps what a wake's row names and links to, from the durable events.
    @MainActor
    func testTheConversationTracksJobsForTheirRows() throws {
        let link = QuietLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try decode(#""event":"background_started","id":"job-1","kind":"job","label":"sleep 570; wc -l out","log":"/tmp/s.jobs/job-1.log""#))
        XCTAssertEqual(c.jobs["job-1"], BackgroundJob(id: "job-1", kind: "job", label: "sleep 570; wc -l out", log: "/tmp/s.jobs/job-1.log"))
        link.onEvent(try decode(#""event":"background_done","id":"job-1","kind":"job","status":"done","summary":"<job-done id=job-1 exit=0>\n26\n</job-done>""#))
        XCTAssertEqual(c.jobs["job-1"]?.status, "done")
        link.onEvent(try decode(#""event":"turn_started","turn":2,"input":"<job-done id=job-1 exit=0>\n26\n</job-done>""#))
        let turn = try XCTUnwrap(c.turns.last)
        guard case .wakes(let rows) = TurnLead(turn) else { return XCTFail("a wake turn") }
        let row = WakeEventRow(event: rows[0], job: c.jobs[rows[0].id])
        XCTAssertEqual(row.headline, "sleep 570; wc -l out")
    }
}

@MainActor
private final class QuietLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    func send(_ op: Op) {}
    func stop() {}
    var endDescription: String { "" }
    var isAlive: Bool { true }
}

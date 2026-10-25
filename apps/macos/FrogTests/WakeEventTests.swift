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
        let lead = TurnLead(wake)
        XCTAssertEqual(lead.wakes.map(\.id), ["mon-1"])
        XCTAssertEqual(lead.opener, .none, "no user bubble")
        XCTAssertEqual(TurnLead(TurnState(number: 1, input: "fix the build")).opener, .prompt)
        XCTAssertTrue(TurnLead(TurnState(number: 1, input: "fix the build")).wakes.isEmpty)
        guard case .sessionMessages(let cards) = TurnLead(TurnState(number: 2, input: "<session-message from=\"s1\" name=\"Chief\">\ngo\n</session-message>")).opener else {
            return XCTFail("a session message is its card")
        }
        XCTAssertEqual(cards.map(\.from), ["s1"])
        XCTAssertEqual(TurnLead(TurnState(number: 3, input: "")).opener, .none)
    }

    /// One batch: a wake turn that took a queued session message shows the wake rows, then the
    /// message's card; a typed message delivered with wakes shows the rows, then the bubble.
    func testABatchTurnShowsItsWakesAheadOfItsInput() {
        let batch = TurnState(
            number: 4,
            input: "<wakeup id=mon-1 after_s=1>pod check</wakeup>",
            more: [MessagePart(text: "<session-message from=\"s9\" name=\"okc manager\">\nserving:true\n</session-message>", images: [])])
        let lead = TurnLead(batch)
        XCTAssertEqual(lead.wakes.map(\.kind), [.timer])
        guard case .sessionMessages(let cards) = lead.opener else { return XCTFail("\(lead.opener)") }
        XCTAssertEqual(cards.first?.name, "okc manager")
        var typed = TurnState(number: 5, input: "next")
        typed.wakes = ["<job-done id=job-1 exit=0>\n26\n</job-done>"]
        let rode = TurnLead(typed)
        XCTAssertEqual(rode.wakes.map(\.id), ["job-1"])
        XCTAssertEqual(rode.opener, .prompt)
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
        let rows = TurnLead(turn).wakes
        XCTAssertEqual(rows.count, 1)
        let row = WakeEventRow(event: rows[0], job: c.jobs[rows[0].id])
        XCTAssertEqual(row.headline, "sleep 570; wc -l out")
    }

    /// Collapsed by default: a wake, a session message and a notice are one quiet line (source
    /// and type, the useful fields), with the full payload behind the click.
    func testSystemRowsAreOneCollapsedLine() throws {
        let wake = try XCTUnwrap(WakeEvent.parse("<monitor-done id=mon-8 status=timeout polls=40>\nno match after 2400s. Last output:\n      23\n</monitor-done>")?.first)
        let line = EventLine(wake: wake, job: nil)
        XCTAssertEqual(line.line, "monitor mon-8 · timed out · no match after 2400s. Last output:")
        XCTAssertFalse(line.line.contains("<"), "never the raw tags")
        XCTAssertTrue(line.payload.contains("23"), "expanding shows the full payload")
        XCTAssertTrue(line.warning)
        let job = BackgroundJob(id: "job-3", kind: "job", label: "sleep 570; wc -l out", log: "/tmp/job-3.log")
        let done = EventLine(wake: try XCTUnwrap(WakeEvent.parse("<job-done id=job-3 exit=0>\n26\n</job-done>")?.first), job: job)
        XCTAssertEqual(done.line, "job job-3 · exit 0 · sleep 570; wc -l out")
        XCTAssertEqual(done.log, "/tmp/job-3.log")

        let message = try XCTUnwrap(SessionMessage.parse("<session-message from=\"s9\" name=\"okc manager\">\nserving:true\nthe pod is up, cost so far $4\n</session-message>"))
        let card = EventLine(message: message)
        XCTAssertEqual(card.line, "okc manager · message · serving:true")
        XCTAssertEqual(card.payload, "serving:true\nthe pod is up, cost so far $4")
        XCTAssertEqual(card.session, "s9", "the title links to the sender")
        let system = EventLine(message: SessionMessage(from: "system", name: "system", body: "Session \"x\" is idle."))
        XCTAssertEqual(system.line, "system · notice · Session \"x\" is idle.")
        XCTAssertEqual(system.payload, "", "one line says it all")

        let notice = EventLine(notice: "approval pending: Bash git push\nwaiting 4m", warning: true)
        XCTAssertEqual(notice.line, "approval pending: Bash git push")
        XCTAssertEqual(notice.payload, "approval pending: Bash git push\nwaiting 4m")
        XCTAssertNil(WakeEvent.parse("why did <job-done id=job-1 exit=0> fail?"), "an unclosed tag isn't a wake (and doesn't hang)")
    }

    /// The composer shows the queue: chips for what's parked, "+N more" past three, and the
    /// copy that says nothing is lost.
    func testPendingChipsBadgeAndCopy() {
        let jobs = ["mon-1": BackgroundJob(id: "mon-1", kind: "monitor", label: "pod past 2h cap")]
        let one = PendingEvents(queued: ["<monitor-done id=mon-1 status=matched polls=3>\nover\n</monitor-done>"], messages: [], jobs: jobs)
        XCTAssertEqual(one.chips.map(\.kind), ["monitor"])
        XCTAssertEqual(one.chips.first?.summary, "mon-1 matched · pod past 2h cap")
        XCTAssertEqual(one.chips.first?.payload, "over", "expanding shows the full payload")
        XCTAssertNil(one.overflow)
        XCTAssertEqual(one.caption(busy: true), "1 pending result · they arrive when this turn ends")
        let many = PendingEvents(
            queued: (1...5).map { "<job-done id=job-\($0) exit=0>\nok\n</job-done>" },
            messages: [SessionMessage(from: "s9", name: "okc manager", body: "serving:true\nmore")])
        XCTAssertEqual(many.chips.count, 6)
        XCTAssertEqual(many.visible.count, 3)
        XCTAssertEqual(many.overflow, "+3 more")
        XCTAssertEqual(many.chips.last?.summary, "message from okc manager: serving:true")
        XCTAssertEqual(many.caption(busy: false), "6 pending results · they go with your next message")
        XCTAssertTrue(PendingEvents(queued: [], messages: []).isEmpty)
    }

    /// Esc keeps the queue (it's the engine's, not the user's), and the flush moves it into
    /// the turn as event rows.
    @MainActor
    func testTheQueueSurvivesAStopAndFlushesIntoTheTurn() throws {
        let link = QuietLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try decode(#""event":"idle""#))
        link.onEvent(try decode(#""event":"turn_started","turn":1,"input":"work""#))
        link.onEvent(try decode(#""event":"queued_events","items":["<wakeup id=mon-1 after_s=1>pod check</wakeup>"]"#))
        XCTAssertEqual(c.queuedEvents.count, 1)
        c.interrupt()
        link.onEvent(try decode(#""event":"turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#))
        link.onEvent(try decode(#""event":"idle""#))
        XCTAssertEqual(c.queuedEvents.count, 1, "a stop keeps the queue")
        XCTAssertEqual(PendingEvents(queued: c.queuedEvents, messages: c.pendingMessages).caption(busy: c.busy),
                       "1 pending result · they go with your next message")
        link.onEvent(try decode(#""event":"turn_started","turn":2,"input":"next""#))
        link.onEvent(try decode(#""event":"queued_events","items":[]"#))
        link.onEvent(try decode(#""event":"wakes_delivered","turn":2,"wakes":["<wakeup id=mon-1 after_s=1>pod check</wakeup>"]"#))
        XCTAssertTrue(c.queuedEvents.isEmpty, "flushed")
        let lead = TurnLead(try XCTUnwrap(c.turns.last))
        XCTAssertEqual(lead.wakes.map(\.id), ["mon-1"], "into the turn as event rows")
        XCTAssertEqual(lead.opener, .prompt)
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

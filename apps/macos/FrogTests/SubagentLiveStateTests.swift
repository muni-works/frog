import XCTest
@testable import Frog

@MainActor
final class SubagentLiveStateTests: XCTestCase {

    @MainActor
    private func envelope(_ seq: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }

    /// A background task's subagent event for an unknown `task-N` id must not create a
    /// phantom parent item — the turn's items stay untouched.
    @MainActor
    func testBackgroundTaskSubagentEventDoesNotCreateParentItem() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"find it""#))
        link.onEvent(try envelope(2, #""event":"subagent","item":"task-1","inner":{"event":"item_started","id":"i1","kind":{"type":"tool_call","name":"Grep","arg":"pattern"}}"#))
        link.onEvent(try envelope(3, #""event":"subagent","item":"task-1","inner":{"event":"item_delta","id":"i1","delta":{"type":"text","text":"thinking text"}}"#))
        link.onEvent(try envelope(4, #""event":"subagent","item":"task-1","inner":{"event":"item_completed","id":"i1","item":{"type":"message","text":"a report"}}"#))

        // No phantom item in the turn.
        XCTAssertEqual(c.turns.last?.items.count ?? 0, 0, "no parent item should be created for a background task's subagent events")
        // The never-finished phantom item must not drive the live answer.
        for item in c.turns.last?.items ?? [] {
            XCTAssertTrue(item.done, "no live item should remain in the parent's turn")
        }
    }

    /// A foreground Task's events still fold into its item as before.
    @MainActor
    func testForegroundTaskSubagentEventsStillFold() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"research agent"}"#))
        link.onEvent(try envelope(3, #""event":"subagent","item":"t1","inner":{"event":"item_started","id":"i1","kind":{"type":"tool_call","name":"Grep","arg":"pattern"}}"#))
        link.onEvent(try envelope(4, #""event":"subagent","item":"t1","inner":{"event":"item_delta","id":"i1","delta":{"type":"output","text":"some output"}}"#))

        let taskItem = try XCTUnwrap(c.turns.last?.items.first { $0.id == "t1" })
        XCTAssertEqual(taskItem.subagent?.items.count, 1, "foreground Task's subagent events fold in")
        XCTAssertEqual(taskItem.subagent?.activity, "Searching pattern", "activity tracks the latest step")
    }

    /// While a foreground Task runs, the live activity line says what the subagent is doing
    /// (the chief tile reads this) instead of falling back to "Here: <folder>".
    @MainActor
    func testLiveActivitySaysSubagentActivityWhileTaskRuns() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"research agent"}"#))
        link.onEvent(try envelope(3, #""event":"subagent","item":"t1","inner":{"event":"item_started","id":"i1","kind":{"type":"tool_call","name":"Read","arg":"apps/FrogKit/UI/main.rs"}}"#))

        let activity = try XCTUnwrap(c.liveActivity, "live activity must say what the subagent is doing")
        XCTAssertEqual(activity, "Subagent: Reading main.rs")
    }

    /// Before the subagent's first step arrives, the live activity still says a subagent runs.
    @MainActor
    func testLiveActivityBeforeFirstSubagentStep() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"research agent"}"#))

        let activity = try XCTUnwrap(c.liveActivity)
        XCTAssertEqual(activity, "Running a subagent…")
    }

    /// Once the Task item completed, the live activity is no longer the subagent's.
    @MainActor
    func testLiveActivityClearsAfterTaskCompletes() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"research agent"}"#))
        link.onEvent(try envelope(3, #""event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"research agent","input":null,"outcome":"ok","output":"report body","display":null}"#))
        // Nothing else is running now: the live activity falls back to the thinking line.
        let activity = c.liveActivity
        XCTAssertNotEqual(activity, "Subagent: Reporting")
    }
}


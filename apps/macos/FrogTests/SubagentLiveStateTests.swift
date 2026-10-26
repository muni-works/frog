import XCTest
@testable import Frog

@MainActor
final class SubagentLiveStateTests: XCTestCase {

    @MainActor
    private func envelope(_ seq: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }

    private func at(_ seq: UInt64, _ created: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":\#(created),\#(body)}"#.utf8))
    }

    /// A conversation whose turn started a background agent `task-1` ("bg research"), which
    /// is now running (the Task call itself returned at once).
    private func backgroundAgent() throws -> (Conversation, LiveLink) {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"research in the background""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"bg research"}"#))
        link.onEvent(try envelope(3, #""event":"background_started","id":"task-1","kind":"task","label":"bg research""#))
        link.onEvent(try envelope(4, #""event":"background","running":1"#))
        link.onEvent(try envelope(5, #""event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"bg research","input":{"background":true},"outcome":"ok","output":"Started background task task-1. It runs on its own.","display":null}"#))
        return (c, link)
    }

    // MARK: Bug: background agents' events made a phantom item in the parent's turn

    /// Its steps fold into its own run; the parent's turn keeps only the finished Task call,
    /// so nothing in the turn looks like an answer being written.
    func testBackgroundAgentStepsFoldIntoItsOwnRun() throws {
        let (c, link) = try backgroundAgent()
        link.onEvent(try envelope(6, #""event":"subagent","item":"task-1","inner":{"event":"item_started","id":"i1","kind":{"type":"tool_call","name":"Grep","arg":"pattern"}}"#))
        link.onEvent(try envelope(7, #""event":"subagent","item":"task-1","inner":{"event":"item_delta","id":"i2","delta":{"type":"text","text":"so far"}}"#))
        let turn = try XCTUnwrap(c.turns.last)
        XCTAssertEqual(turn.items.map(\.id), ["t1"], "no phantom item for task-1")
        XCTAssertTrue(turn.items.allSatisfy(\.done))
        XCTAssertEqual(c.agentRuns["task-1"]?.steps, 1)
        XCTAssertEqual(c.agentRuns["task-1"]?.items.count, 1, "deltas don't fold into a background run")
        XCTAssertNotEqual(ActivityLabel.live(turn, in: c), "Writing the answer")
        let agent = try XCTUnwrap(c.agents.first)
        XCTAssertEqual(agent.id, "task-1")
        XCTAssertEqual(agent.title, "bg research")
        XCTAssertEqual(agent.state, .running)
        XCTAssertTrue(agent.background)
        XCTAssertEqual(agent.activity, "Searching pattern")
        XCTAssertEqual(c.agents.count, 1, "the Task call that started it isn't an agent of its own")
    }

    /// A background agent asking permission: the request names its job, so no item appears;
    /// its row says it waits on you.
    func testBackgroundAgentPermissionMakesNoItem() throws {
        let (c, link) = try backgroundAgent()
        link.onEvent(try envelope(6, #""event":"permission_request","id":"p1","item":"task-1","name":"Bash","arg":"cargo bench","always":"cargo bench""#))
        XCTAssertEqual(c.turns.last?.items.map(\.id), ["t1"])
        XCTAssertEqual(c.agents.first?.state, .waiting)
        link.onEvent(try envelope(7, #""event":"permission_resolved","id":"p1","decision":"allow""#))
        XCTAssertEqual(c.agents.first?.state, .running)
    }

    /// A background agent the log left "running" died with its engine: no row for it.
    func testStaleBackgroundAgentHasNoRow() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"background_started","id":"task-1","kind":"task","label":"old""#))
        XCTAssertTrue(c.agents.isEmpty)
    }

    /// A finished background agent: done or failed, with the failure's first line.
    func testBackgroundAgentEnds() throws {
        let (c, link) = try backgroundAgent()
        link.onEvent(try envelope(6, #""event":"background_done","id":"task-1","kind":"task","status":"failed","summary":"rate limited (429)\nretry later""#))
        link.onEvent(try envelope(7, #""event":"background","running":0"#))
        let agent = try XCTUnwrap(c.agents.first)
        XCTAssertEqual(agent.state, .failed)
        XCTAssertEqual(agent.activity, "rate limited (429)")
    }

    // MARK: The agent-step log, replayed

    /// Steps replayed from the log fold into the Task's run, and the run's clock starts when
    /// the Task did (not when the log was read: the "29883095m" header).
    func testReplayedStepsKeepTheTasksClock() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        let t0: UInt64 = 1_700_000_000_000
        link.onEvent(try at(1, t0, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try at(2, t0 + 10, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"research"}"#))
        link.onEvent(try at(3, t0 + 20, #""event":"subagent","item":"t1","inner":{"event":"item_started","id":"s1","kind":{"type":"tool_call","name":"Read","arg":"main.rs"}}"#))
        link.onEvent(try at(4, t0 + 30, #""event":"subagent","item":"t1","inner":{"event":"item_completed","id":"s1","item":{"type":"tool_call","name":"Read","arg":"main.rs","input":null,"outcome":"ok","output":"fn main","display":null}}"#))
        link.onEvent(try at(5, t0 + 40, #""event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"research","input":null,"outcome":"ok","output":"it's in main.rs","display":null}"#))
        let task = try XCTUnwrap(c.turns.last?.items.first)
        let run = try XCTUnwrap(task.subagent)
        XCTAssertEqual(run.steps, 1)
        XCTAssertTrue(run.items[0].done)
        XCTAssertEqual(run.startedAt, Date(timeIntervalSince1970: Double(t0 + 10) / 1000))
    }

    // MARK: Bug: the chief tile said "Here: <folder>" while a subagent worked

    /// After you answer an agent's permission prompt it goes on working, and the tile goes
    /// on saying what it's doing.
    func testLiveActivityAfterAnApproval() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"writer"}"#))
        link.onEvent(try envelope(3, #""event":"permission_request","id":"p1","item":"t1","name":"Write","arg":"new.txt","always":"Write""#))
        XCTAssertNil(c.liveActivity, "waiting on you: the tile says so itself")
        XCTAssertEqual(c.agents.first?.state, .waiting)
        link.onEvent(try envelope(4, #""event":"permission_resolved","id":"p1","decision":"allow""#))
        link.onEvent(try envelope(5, #""event":"subagent","item":"t1","inner":{"event":"item_started","id":"s1","kind":{"type":"tool_call","name":"Read","arg":"src/new.txt"}}"#))
        XCTAssertEqual(c.liveActivity, "Subagent: Reading new.txt")
        XCTAssertEqual(c.agents.first?.state, .running)
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
        XCTAssertEqual(activity, "Subagent: Starting")
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


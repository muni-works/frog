import XCTest
@testable import Frog

/// Agents (Task calls) as calm steps: the per-turn agent list for the sidebar, the activity
/// wording, and the pill's waiting text.
@MainActor
final class AgentRowTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func taskItem(id: String, arg: String, done: Bool = false, outcome: ToolOutcome? = nil,
                          subagent: SubagentRun? = nil, startedAt: Date? = nil) -> ItemState {
        var item = ItemState(id: id, kind: .tool(name: "Task", arg: arg))
        item.done = done
        if let outcome {
            item.result = Item.ToolResult(name: "Task", arg: arg, input: nil, outcome: outcome, output: "", display: nil)
        }
        if let subagent { item.subagent = subagent }
        item.startedAt = startedAt
        return item
    }

    private func agentTool(_ id: String, _ name: String, _ arg: String, done: Bool = true,
                           outcome: ToolOutcome = .ok) -> ItemState {
        var item = ItemState(id: id, kind: .tool(name: name, arg: arg))
        item.done = done
        if done { item.result = Item.ToolResult(name: name, arg: arg, input: nil, outcome: outcome, output: "", display: nil) }
        return item
    }

    // MARK: Agents of a turn

    func testAgentsOfRunningTurn() {
        var run = SubagentRun()
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "apps/main.rs")))
        let turn = TurnState(input: "go", items: [
            agentTool("a", "Read", "x.swift"),
            taskItem(id: "t1", arg: "audit the sidebar", subagent: run, startedAt: t0),
            taskItem(id: "t2", arg: "", done: true, outcome: .ok),
            taskItem(id: "t3", arg: "survey bugs", done: true, outcome: .error),
        ])
        let agents = turn.agents
        XCTAssertEqual(agents.count, 3)
        XCTAssertEqual(agents[0].id, "t1")
        XCTAssertEqual(agents[0].title, "audit the sidebar")
        XCTAssertEqual(agents[0].state, .running)
        XCTAssertEqual(agents[0].activity, "Reading main.rs")
        XCTAssertEqual(agents[0].startedAt, t0)
        XCTAssertEqual(agents[1].state, .done)
        XCTAssertEqual(agents[2].state, .failed)
    }

    func testAgentPlanProgressFromTodoWrite() throws {
        var run = SubagentRun()
        let todos: JSONValue = .array([
            .object(["content": .string("a"), "status": .string("completed")]),
            .object(["content": .string("b"), "status": .string("completed")]),
            .object(["content": .string("c"), "status": .string("pending")]),
        ])
        let result = Item.ToolResult(name: "TodoWrite", arg: "", input: .object(["todos": todos]), outcome: .ok, output: "", display: nil)
        run.apply(.itemCompleted(id: "td", item: .toolCall(result)))
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "x.rs")))

        let turn = TurnState(input: "go", items: [taskItem(id: "t1", arg: "worker", subagent: run)])
        let agent = try XCTUnwrap(turn.agents.first)
        XCTAssertEqual(agent.planDone, 2)
        XCTAssertEqual(agent.planTotal, 3)
    }

    func testFailureHeadIsFirstLine() {
        var failed = taskItem(id: "t1", arg: "worker", done: true, outcome: .error)
        failed.result?.output = "rate limited by provider (429)\nretry later"
        let turn = TurnState(input: "go", items: [failed])
        let agent = turn.agents[0]
        XCTAssertEqual(agent.state, .failed)
        XCTAssertEqual(agent.activity, "rate limited by provider (429)")
    }

    // MARK: Activity wording

    func testSummaryCountsAgents() {
        let steps = [
            agentTool("a", "Read", "x.swift"),
            agentTool("t1", "Task", "one"),
            agentTool("t2", "Task", "two"),
            agentTool("t3", "Task", "three"),
        ]
        XCTAssertEqual(ActivityWords.plain(ActivityGroup(steps: steps).summary), "Read x.swift, ran 3 agents")
    }

    func testAgentFailureInSummary() {
        let steps = [agentTool("t1", "Task", "worker", outcome: .error)]
        XCTAssertEqual(ActivityWords.plain(ActivityGroup(steps: steps).summary), "Ran an agent, 1 failed")
    }

    func testAgentRowAndNowWords() {
        XCTAssertEqual(ActivityWords.row(agentTool("t1", "Task", "audit")), "Agent: audit")
        var run = SubagentRun()
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "apps/main.rs")))
        var item = ItemState(id: "t1", kind: .tool(name: "Task", arg: "audit"))
        item.subagent = run
        XCTAssertEqual(ActivityWords.now(item), "Agent: Reading main.rs…")
    }

    // MARK: Pill live text, and the transcript's live status

    private func envelope(_ seq: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }

    /// A turn that ran two agents (one done, one failed) and now waits on a third.
    private func waitingTurn() -> TurnState {
        var run = SubagentRun()
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "x.rs")))
        return TurnState(input: "go", items: [
            taskItem(id: "t2", arg: "survey", done: true, outcome: .ok),
            taskItem(id: "t3", arg: "mapper", done: true, outcome: .error),
            taskItem(id: "t1", arg: "audit", subagent: run),
        ])
    }

    func testPillWaitsOnOneAgent() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false)
        XCTAssertEqual(ActivityLabel.live(waitingTurn(), in: c), "Waiting on 1 agent")
    }

    /// Background agents still at work are waited on too.
    func testPillCountsBackgroundAgents() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"background_started","id":"task-1","kind":"task","label":"a""#))
        link.onEvent(try envelope(3, #""event":"background_started","id":"task-2","kind":"task","label":"b""#))
        link.onEvent(try envelope(4, #""event":"background","running":2"#))
        link.onEvent(try envelope(5, #""event":"item_started","id":"t9","kind":{"type":"tool_call","name":"Task","arg":"c"}"#))
        let turn = try XCTUnwrap(c.turns.last)
        XCTAssertEqual(ActivityLabel.live(turn, in: c), "Waiting on 3 agents")
    }

    /// Not waiting on an agent: the pill says the step, as before.
    func testPillWithoutAgents() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false)
        let turn = TurnState(input: "go", items: [agentTool("a", "Read", "x.swift", done: false)])
        XCTAssertEqual(ActivityLabel.live(turn, in: c), "Reading x.swift")
        XCTAssertNil(c.agentStatus(turn))
    }

    func testTranscriptLiveStatusCountsTheTurnsAgents() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false)
        XCTAssertEqual(c.agentStatus(waitingTurn()), "Waiting on 1 agent · 1 done · 1 failed…")
        let first = TurnState(input: "go", items: [taskItem(id: "t1", arg: "audit")])
        XCTAssertEqual(c.agentStatus(first), "Waiting on 1 agent…")
    }

    /// The transcript's step rows: "Agent: X", failure as "· failed" (the row's outcome).
    func testStepRowWords() {
        XCTAssertEqual(ActivityWords.row(agentTool("t1", "Task", "survey bg tasks", outcome: .error)), "Agent: survey bg tasks")
        XCTAssertEqual(ActivityWords.row(agentTool("t1", "Task", "")), "Ran an agent")
    }

    /// The Task call that started a background agent isn't an agent step of the turn.
    func testBackgroundLauncherIsNotAnAgent() {
        var launcher = taskItem(id: "t1", arg: "bg", done: true, outcome: .ok)
        launcher.result?.output = "Started background task task-1. It runs on its own."
        XCTAssertTrue(launcher.startsBackgroundAgent)
        XCTAssertTrue(TurnState(input: "go", items: [launcher]).agents.isEmpty)
    }

    // MARK: Sidebar rows (AgentList)

    private func agent(_ id: String, _ state: AgentRowInfo.State, turn: UInt64 = 1,
                       background: Bool = false) -> AgentRowInfo {
        AgentRowInfo(id: id, title: id, state: state, activity: nil, steps: 0, planDone: nil,
                     planTotal: nil, startedAt: nil, endedAt: nil, turn: turn, background: background)
    }

    /// While the turn runs, every agent of it has a row: needs-you first, then working, then
    /// failed (it stays red on its own row), then done.
    func testRowsWhileTheTurnRuns() {
        let list = AgentList([agent("a", .done), agent("b", .failed), agent("c", .running), agent("d", .waiting)],
                             running: 1, last: 1)
        XCTAssertEqual(list.rows.map(\.id), ["d", "c", "b", "a"])
        XCTAssertTrue(list.folded.isEmpty)
    }

    /// The turn ended: finished agents fold into "N done · M failed"; one still working
    /// (a background agent) keeps its row.
    func testFinishedAgentsFoldWhenTheTurnEnds() {
        let list = AgentList([agent("a", .done), agent("b", .failed), agent("c", .done),
                              agent("d", .running, background: true)], running: nil, last: 1)
        XCTAssertEqual(list.rows.map(\.id), ["d"])
        XCTAssertEqual(list.folded.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(list.done, 2)
        XCTAssertEqual(list.failed, 1)
    }

    /// A background agent's report wakes a turn of its own: its fold stays through that
    /// turn, and goes once the session has moved on.
    func testTheFoldGoesOnceTheSessionMovesOn() {
        let done = [agent("a", .done, turn: 3, background: true)]
        XCTAssertEqual(AgentList(done, running: nil, last: 4).folded.count, 1)
        XCTAssertTrue(AgentList(done, running: nil, last: 5).isEmpty)
        // A new turn that runs without agents: last turn's finished ones aren't rows.
        XCTAssertTrue(AgentList(done, running: 5, last: 5).rows.isEmpty)
    }

    /// From the live conversation: blocked on you → waiting; the parent's live state says it.
    func testBlockedAgentNeedsYou() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"run the bench"}"#))
        link.onEvent(try envelope(3, #""event":"permission_request","id":"p1","item":"t1","name":"Bash","arg":"cargo bench","always":"cargo bench""#))
        let list = c.agentList
        XCTAssertEqual(list.rows.map(\.state), [.waiting])
        XCTAssertEqual(list.rows.first?.title, "run the bench")
        XCTAssertNotNil(c.permission, "the session itself is waiting on you: the parent row bubbles")
    }

    /// From the live conversation: a failed agent stays a red row while the turn runs, then
    /// folds as "1 failed" once it ends.
    func testFailedAgentThenTurnEnd() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"survey"}"#))
        link.onEvent(try envelope(3, #""event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"survey","input":null,"outcome":"error","output":"rate limited (429)\nlater","display":null}"#))
        var list = c.agentList
        XCTAssertEqual(list.rows.map(\.state), [.failed])
        XCTAssertEqual(list.rows.first?.activity, "rate limited (429)")
        link.onEvent(try envelope(4, #""event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#))
        list = c.agentList
        XCTAssertTrue(list.rows.isEmpty)
        XCTAssertEqual(list.failed, 1)
        XCTAssertEqual(list.done, 0)
    }

    /// The row's right edge: the plan's "3/5", else steps and time.
    func testRowProgressWords() {
        var a = agent("a", .running)
        a.steps = 4
        a.startedAt = t0
        XCTAssertEqual(AgentRow.progress(a, now: t0.addingTimeInterval(42)), "4 steps · 42s")
        a.planDone = 3
        a.planTotal = 5
        XCTAssertEqual(AgentRow.progress(a, now: t0.addingTimeInterval(42)), "3/5")
        XCTAssertNil(AgentRow.progress(agent("b", .done), now: t0))
    }
}

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

    // MARK: Pill live text

    func testLiveTextWaitsOnAgents() {
        var run = SubagentRun()
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "x.rs")))
        let turn = TurnState(input: "go", items: [
            taskItem(id: "t1", arg: "audit", subagent: run),
            taskItem(id: "t2", arg: "survey", done: true, outcome: .ok),
            taskItem(id: "t3", arg: "mapper", done: true, outcome: .error),
            taskItem(id: "t4", arg: "second runner", subagent: run),
        ])
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false)
        XCTAssertEqual(ActivityLabel.live(turn, in: c), "Waiting on 2 agents · 1 failed")
    }

    func testLiveTextSingleAgent() {
        var run = SubagentRun()
        run.apply(.itemStarted(id: "i1", kind: .toolCall(name: "Read", arg: "x.rs")))
        let turn = TurnState(input: "go", items: [taskItem(id: "t1", arg: "audit", subagent: run)])
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false)
        XCTAssertEqual(ActivityLabel.live(turn, in: c), "Waiting on an agent…")
    }
}

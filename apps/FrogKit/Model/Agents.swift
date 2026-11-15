import Foundation

/// One agent (a `Task` call) of a session, for the sidebar: what it is, what it's doing, how
/// far along, and whether it needs you. Derived from the open conversation's live state —
/// agents are not sessions (see NOTES.md, the live-only decision).
struct AgentRowInfo: Identifiable, Equatable {
    enum State: Equatable {
        /// Still working.
        case running
        /// Its permission prompt or question is up: it needs you.
        case waiting
        /// It ended with an error.
        case failed
        /// It reported back and the parent took it.
        case done

        /// Most urgent first, for row order.
        var rank: Int {
            switch self {
            case .waiting: 0
            case .running: 1
            case .failed: 2
            case .done: 3
            }
        }
    }

    /// The Task call's item id, or a background agent's job id (`task-N`).
    let id: String
    /// The Task's description, or "agent" when the model sent none.
    let title: String
    var state: State
    /// What it's doing right now ("Reading main.rs"), or the failure's first line.
    var activity: String?
    var steps: Int
    /// Its own TodoWrite plan: done and total, when it wrote one.
    var planDone: Int?
    var planTotal: Int?
    var startedAt: Date?
    var endedAt: Date?
    /// The parent's turn that started it.
    var turn: UInt64?
    /// `Task {background: true}`: the parent's turn doesn't wait for it.
    var background = false

    var finished: Bool { state == .done || state == .failed }
}

/// A session's agents as the sidebar shows them: one row each while they matter (working,
/// waiting on you, or finished during the turn that's running), the rest folded into one
/// "› N done · M failed" line once the turn that ran them has ended.
struct AgentList: Equatable {
    var rows: [AgentRowInfo] = []
    var folded: [AgentRowInfo] = []

    var done: Int { folded.filter { $0.state == .done }.count }
    var failed: Int { folded.filter { $0.state == .failed }.count }
    var isEmpty: Bool { rows.isEmpty && folded.isEmpty }

    /// `agents` in call order; `running` is the number of the parent's turn that's running,
    /// `last` the number of its last turn. The fold holds the latest agent turn's finished
    /// agents, while that's the last turn or the one before (a background agent's report
    /// wakes a turn of its own); older ones are settled and say nothing.
    init(_ agents: [AgentRowInfo], running: UInt64?, last: UInt64?) {
        let latest = agents.compactMap(\.turn).max()
        let recent = latest.map { l in last.map { l + 1 >= $0 } ?? true } ?? false
        for agent in agents {
            if !agent.finished || (running != nil && agent.turn == running) {
                rows.append(agent)
            } else if recent, agent.turn == latest {
                folded.append(agent)
            }
        }
        // Most urgent first; call order within a state (the sort is stable).
        rows = rows.enumerated().sorted { a, b in
            a.element.state.rank != b.element.state.rank
                ? a.element.state.rank < b.element.state.rank : a.offset < b.offset
        }.map(\.element)
    }

    init() {}
}

extension SubagentRun {
    /// Its own TodoWrite plan: done and total, from its last finished TodoWrite call.
    var plan: (done: Int, total: Int)? {
        guard let todos = items.last(where: { step in
            if case .tool("TodoWrite", _) = step.kind { return step.done }
            return false
        })?.result?.input?["todos"]?.array, !todos.isEmpty else { return nil }
        return (todos.filter { $0["status"]?.string == "completed" }.count, todos.count)
    }
}

extension ItemState {
    /// A `Task` call that started a background agent: it returned at once, and the agent is
    /// the background job it names, not this item.
    var startsBackgroundAgent: Bool {
        guard case .tool("Task", _) = kind, let r = result else { return false }
        if case .bool(true)? = r.input?["background"] { return true }
        return r.output.hasPrefix("Started background task ")
    }
}

/// The first line of a failure, short enough for one row.
func agentFailureHead(_ text: String) -> String? {
    let line = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return line.isEmpty ? nil : String(line.prefix(80))
}

extension TurnState {
    /// The agents (Task calls) of this turn, in call order.
    /// (Not the calls that started background agents: those are the conversation's jobs.)
    var agents: [AgentRowInfo] {
        items.compactMap { item -> AgentRowInfo? in
            guard case .tool("Task", let arg) = item.kind, !item.startsBackgroundAgent else { return nil }
            let state: AgentRowInfo.State
            if !item.done {
                state = item.needsPermission ? .waiting : .running
            } else if item.result?.outcome == .ok {
                state = .done
            } else {
                state = .failed
            }
            let plan = item.subagent?.plan
            var activity: String?
            switch state {
            case .failed: activity = item.result.flatMap { agentFailureHead($0.output) }
            case .running: activity = item.subagent?.activity
            case .waiting, .done: break
            }
            return AgentRowInfo(id: item.id, title: arg.isEmpty ? "agent" : arg, state: state,
                                activity: activity, steps: item.subagent?.steps ?? 0,
                                planDone: plan?.done, planTotal: plan?.total,
                                startedAt: item.startedAt, endedAt: item.endedAt, turn: number)
        }
    }
}

extension Conversation {
    /// Every agent the sidebar can speak of, in call order: the waited-on agents of the last
    /// turn (only it: older turns are settled, and this runs as the turn streams), then the
    /// background agents of old logs. Background Tasks are retired (parallel work is a child
    /// session in the started-by tree), so those only ever replay, as plain settled rows: one
    /// the log left "running" died with its engine and isn't shown.
    var agents: [AgentRowInfo] {
        var out = turns.last?.agents ?? []
        if let p = permission, let i = out.firstIndex(where: { $0.id == p.item && !$0.finished }) {
            out[i].state = .waiting
        }
        let tasks = jobs.values.filter { $0.kind == "task" }
            .sorted { ($0.id.split(separator: "-").last.flatMap { Int($0) } ?? 0)
                < ($1.id.split(separator: "-").last.flatMap { Int($0) } ?? 0) }
        for job in tasks {
            let run = agentRuns[job.id]
            let state: AgentRowInfo.State
            switch job.status {
            case "running": continue
            case "done", "stopped": state = .done
            default: state = .failed
            }
            let plan = run?.plan
            out.append(AgentRowInfo(
                id: job.id, title: job.label.isEmpty ? "agent" : job.label, state: state,
                activity: state == .failed ? job.head : nil,
                steps: run?.steps ?? 0, planDone: plan?.done, planTotal: plan?.total,
                startedAt: job.startedAt, endedAt: run?.endedAt, turn: job.turn, background: true))
        }
        return out
    }

    /// The sidebar's agent rows and fold line for this session.
    var agentList: AgentList {
        let running = turns.last.flatMap { $0.finished ? nil : $0.number }
        return AgentList(agents, running: running, last: turns.last?.number)
    }

    /// "Waiting on 1 agent", while `turn` waits on one of its own (a `Task` call in hand).
    /// Nil when it isn't waiting on one. (Parallel work is child sessions, shown in the tree.)
    func waitingOnAgents(_ turn: TurnState) -> String? {
        guard !turn.finished,
              let current = turn.items.last(where: { !$0.done && $0.kind != .message }),
              case .tool("Task", _) = current.kind else { return nil }
        return "Waiting on 1 agent"
    }

    /// The transcript's live line while `turn` waits on an agent: "Waiting on 1 agent · 2 done…"
    /// (this turn's agents that already finished, and how many of them failed).
    func agentStatus(_ turn: TurnState) -> String? {
        guard let waiting = waitingOnAgents(turn) else { return nil }
        let mine = turn.agents.filter(\.finished)
        let failed = mine.filter { $0.state == .failed }.count
        var text = waiting
        if mine.count > failed { text += " · \(mine.count - failed) done" }
        if failed > 0 { text += " · \(failed) failed" }
        return text + "…"
    }
}

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

    /// The Task call's item id.
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
}

extension TurnState {
    /// The agents (Task calls) of this turn, in call order.
    var agents: [AgentRowInfo] {
        items.compactMap { item -> AgentRowInfo? in
            guard case .tool("Task", let arg) = item.kind else { return nil }
            let state: AgentRowInfo.State
            if !item.done {
                state = .running
            } else if item.result?.outcome == .ok {
                state = .done
            } else {
                state = .failed
            }
            // Its own plan, from its last completed TodoWrite call.
            var planDone: Int?, planTotal: Int?
            if let todos = item.subagent?.items.last(where: { step in
                if case .tool("TodoWrite", _) = step.kind { return step.done }
                return false
            })?.result?.input?["todos"]?.array {
                planTotal = todos.count
                planDone = todos.filter { $0["status"]?.string == "completed" }.count
            }
            var activity: String?
            switch state {
            case .failed:
                activity = item.result?.output.split(separator: "\n").first.map(String.init)
            case .running:
                activity = item.subagent?.activity
            case .waiting, .done:
                break
            }
            return AgentRowInfo(id: item.id, title: arg.isEmpty ? "agent" : arg, state: state,
                                activity: activity, steps: item.subagent?.steps ?? 0,
                                planDone: planDone, planTotal: planTotal,
                                startedAt: item.startedAt, endedAt: item.endedAt)
        }
    }
}

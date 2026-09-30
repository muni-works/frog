import ActivityKit
import Foundation

/// Keeps the lock screen's live view of a turn in step with the conversation: started when a
/// turn begins (iOS lets only a running app start one), moved along as steps land, at most twice
/// a second, and ended with the outcome. While the app sleeps, the Mac moves it along with pushes
/// to the activity's token.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    private var current: Activity<TurnActivity>?
    private var last: TurnActivity.ContentState?
    private var lastSent = Date.distantPast
    private var queued: Task<Void, Never>?

    func follow(_ m: SessionModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = m.activityState
        if m.busy {
            if let current, current.attributes.session == m.id {
                update(state)
            } else {
                start(m, state)
            }
        } else if let current, current.attributes.session == m.id {
            end(current, state)
        }
    }

    private func start(_ m: SessionModel, _ state: TurnActivity.ContentState) {
        if let old = current { end(old, last ?? state) }
        let attributes = TurnActivity(session: m.id, title: m.session.title, local: m.isLocal,
                                      startedAt: m.turns.last?.startedAt ?? .now)
        let content = ActivityContent(state: state, staleDate: nil)
        // Pushes need the push entitlement; without it (the simulator, a free team) the activity
        // still runs, moved along by the app while it's awake.
        let activity = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
            ?? (try? Activity.request(attributes: attributes, content: content, pushType: nil))
        guard let activity else { return }
        current = activity
        last = state
        lastSent = .now
        Task {
            for await token in activity.pushTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                Remote.shared.registerActivity(session: m.id, token: hex)
            }
        }
    }

    private func update(_ state: TurnActivity.ContentState) {
        guard state != last else { return }
        last = state
        queued?.cancel()
        let wait = max(0, 0.5 - Date.now.timeIntervalSince(lastSent))
        queued = Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let current = self.current, let state = self.last else { return }
            self.lastSent = .now
            // ActivityKit's handle isn't Sendable, but updating it from here is how it's meant to be used.
            nonisolated(unsafe) let a = current
            await a.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func end(_ activity: Activity<TurnActivity>, _ state: TurnActivity.ContentState) {
        queued?.cancel()
        if current?.id == activity.id { current = nil }
        last = nil
        nonisolated(unsafe) let a = activity
        Task {
            await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4 * 60))
        }
    }
}

extension SessionModel {
    /// What the lock screen shows for this conversation right now.
    var activityState: TurnActivity.ContentState {
        let turn = turns.last
        let steps = turn?.entries.filter { if case .tool = $0.kind { true } else { false } }.count ?? 0
        if let p = permission {
            let q: String
            switch p.name {
            case "Bash": q = "Run \(p.arg.split(separator: "\n").first.map(String.init) ?? p.arg)?"
            case "Edit", "Write": q = "\(p.name) \((p.arg as NSString).lastPathComponent)?"
            default: q = "Use \(p.name)?"
            }
            return .init(mood: "waiting", activity: q, steps: steps, waiting: true, permission: p.id)
        }
        if !busy, let turn {
            let answer = turn.entries.last { $0.kind == .message }?.text ?? ""
            let line = answer.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            switch turn.end {
            case .error(let e)?: return .init(mood: "sad", activity: e.description, steps: steps)
            case .cancelled?, .denied?: return .init(mood: "idle", activity: "Stopped", steps: steps)
            default: return .init(mood: "done", activity: line.map(String.init) ?? "Done", steps: steps)
            }
        }
        return .init(mood: mood.name, activity: activityLine, steps: steps)
    }

    /// The step in hand, in words.
    var activityLine: String {
        guard let e = turns.last?.entries.last(where: { $0.kind != .notice }) else { return "Thinking" }
        switch e.kind {
        case .tool(let name, let arg) where !e.done:
            let t = StepRow.short(arg)
            switch name {
            case "Read": return "Reading \(t)"
            case "Grep": return "Searching for \(t)"
            case "Glob": return "Finding \(t)"
            case "Bash": return "Running \(t)"
            case "Edit": return "Editing \(t)"
            case "Write": return "Writing \(t)"
            case "WebFetch": return "Reading a web page"
            case "WebSearch": return "Searching the web"
            default: return "Using \(name)"
            }
        case .message where !e.done: return "Writing the answer"
        default: return "Thinking"
        }
    }
}

extension FrogMood {
    var name: String {
        switch self {
        case .idle: "idle"
        case .reading: "reading"
        case .thinking: "thinking"
        case .working: "working"
        case .done: "done"
        case .waiting: "waiting"
        case .sad: "sad"
        }
    }
}

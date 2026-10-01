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

    func follow(_ c: Conversation) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let id = c.sessionID else { return }
        let state = c.activityState
        if c.busy {
            if let current, current.attributes.session == id {
                update(state)
            } else {
                start(c, id, state)
            }
        } else if let current, current.attributes.session == id {
            end(current, state)
        }
    }

    private func start(_ c: Conversation, _ id: String, _ state: TurnActivity.ContentState) {
        if let old = current { end(old, last ?? state) }
        let title = c.title ?? Remote.shared.sessions.first { $0.id == id }?.title ?? "frog"
        let cloud = c.status.map { ModelIdentity.of($0.model, in: Remote.shared.models).place.isCloud } ?? false
        let attributes = TurnActivity(session: id, title: title, local: !cloud,
                                      startedAt: c.turns.last?.startedAt ?? .now)
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
                Remote.shared.registerActivity(session: id, token: hex)
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

extension Conversation {
    /// What the lock screen shows for this conversation right now, in the Mac's words.
    var activityState: TurnActivity.ContentState {
        let turn = turns.last
        let steps = turn?.items.filter { if case .tool = $0.kind { true } else { false } }.count ?? 0
        if let p = permission {
            return .init(mood: mood.name, activity: p.question, steps: steps, waiting: true, permission: p.id)
        }
        if !busy, let turn {
            let answer = turn.items.last { $0.kind == .message }?.text ?? ""
            let line = answer.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            switch turn.end {
            case .error(let e)?: return .init(mood: "sad", activity: e.description, steps: steps)
            case .cancelled?, .denied?: return .init(mood: "idle", activity: "Stopped", steps: steps)
            default: return .init(mood: "done", activity: line.map(String.init) ?? "Done", steps: steps)
            }
        }
        let now = turn?.items.last { !$0.done && $0.kind != .message }
        return .init(mood: mood.name, activity: now.map(ActivityWords.now) ?? "Thinking…", steps: steps)
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

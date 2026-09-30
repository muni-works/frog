import Foundation
import Observation

/// One conversation as the phone sees it: the engine's events folded into turns, the same way
/// the Mac's `Conversation` does, minus the parts that belong to the Mac (sounds, stats, titles).
@MainActor
@Observable
final class SessionModel: Identifiable {
    struct Entry: Identifiable {
        enum Kind: Equatable {
            case message, reasoning, notice
            case tool(name: String, arg: String)
        }

        let id: String
        var kind: Kind
        var text = ""
        var output = ""
        var result: Item.ToolResult?
        var done = false
        var needsPermission = false
    }

    struct Turn: Identifiable {
        let id = UUID()
        var number: UInt64?
        var input: String
        var entries: [Entry] = []
        var end: EndReason?
        var usage: TurnUsage?
        /// Sent from this phone (it springs in, like the Mac's sent bubble).
        var sentHere = false
        var finished: Bool { end != nil }
    }

    let id: String
    let session: RemoteSession
    private(set) var turns: [Turn] = []
    private(set) var busy = false
    private(set) var permission: PermissionRequest?
    private(set) var status: Status?
    /// History is still arriving.
    private(set) var loading = true
    var isOpenOnMac: Bool
    /// The last durable event seen, to pick up from after a reconnect.
    private(set) var lastSeq: UInt64 = 0
    @ObservationIgnored private weak var remote: Remote?

    init(session: RemoteSession, remote: Remote) {
        id = session.id
        self.session = session
        self.remote = remote
        isOpenOnMac = session.open
    }

    var model: String { status?.model ?? session.model }
    var isLocal: Bool { Models.isLocal(model) }

    // MARK: Actions

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(Turn(number: nil, input: text, sentHere: true))
        busy = true
        remote?.send(op: ["op": "submit", "text": text], in: id)
    }

    func answer(_ decision: Decision) {
        guard let p = permission else { return }
        remote?.send(op: ["op": "permission", "id": p.id, "decision": decision.rawValue], in: id)
        permission = nil
    }

    func interrupt() {
        remote?.send(op: ["op": "interrupt"], in: id)
    }

    // MARK: Events

    func synced() {
        loading = false
    }

    func note(_ text: String) {
        let e = Entry(id: UUID().uuidString, kind: .notice, text: text, done: true)
        if turns.isEmpty { turns.append(Turn(number: nil, input: "")) }
        turns[turns.count - 1].entries.append(e)
        // A message the Mac couldn't take isn't running.
        if let last = turns.indices.last, turns[last].sentHere, turns[last].number == nil {
            turns[last].end = .cancelled
            busy = false
        }
    }

    func apply(_ env: Envelope) {
        if env.event.isDurable { lastSeq = max(lastSeq, env.seq) }
        switch env.event {
        case .turnStarted(let n, let input, _):
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
            } else if !turns.contains(where: { $0.number == n }) {
                turns.append(Turn(number: n, input: input))
            }
            if !loading { busy = true }
        case .turnEnded(let n, let reason, let usage):
            if let i = turns.lastIndex(where: { $0.number == n }) {
                turns[i].end = reason
                turns[i].usage = usage
            }
        case .itemStarted(let id, let kind):
            upsert(id) { $0.kind = Self.kind(kind) }
        case .itemDelta(let id, let delta):
            upsert(id) { e in
                switch delta {
                case .text(let t), .reasoning(let t): e.text += t
                case .output(let t): e.output += t
                }
            }
        case .itemCompleted(let id, let item):
            upsert(id) { e in
                e.done = true
                e.needsPermission = false
                switch item {
                case .message(let t): e.kind = .message; e.text = t
                case .reasoning(let t): e.kind = .reasoning; e.text = t
                case .toolCall(let r): e.kind = .tool(name: r.name, arg: r.arg); e.result = r
                }
            }
        case .permissionRequest(let req):
            permission = req
            upsert(req.item) { $0.needsPermission = true }
        case .permissionResolved:
            permission = nil
        case .status(let s):
            status = s
        case .idle:
            busy = false
            permission = nil
        case .notice(let level, let message) where level == "warn":
            note(message)
        case .error(let e):
            note(e.description)
        default:
            break
        }
    }

    private static func kind(_ k: ItemKind) -> Entry.Kind {
        switch k {
        case .message: .message
        case .reasoning: .reasoning
        case .toolCall(let name, let arg): .tool(name: name, arg: arg)
        }
    }

    private func upsert(_ id: String, _ update: (inout Entry) -> Void) {
        for t in turns.indices.reversed() {
            if let i = turns[t].entries.firstIndex(where: { $0.id == id }) {
                update(&turns[t].entries[i])
                return
            }
        }
        if turns.isEmpty { turns.append(Turn(number: nil, input: "")) }
        var e = Entry(id: id, kind: .message)
        update(&e)
        turns[turns.count - 1].entries.append(e)
    }
}

extension Event {
    /// Mirrors the engine's `Event::is_durable`: what the session log keeps.
    var isDurable: Bool {
        switch self {
        case .turnStarted, .turnEnded, .itemStarted, .itemCompleted, .permissionResolved, .autoApproved,
             .compacted, .contextPruned, .modelChanged, .folderChanged, .modeChanged, .titled:
            true
        default:
            false
        }
    }
}

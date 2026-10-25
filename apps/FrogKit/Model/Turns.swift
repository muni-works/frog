import Foundation

/// One entry in a turn: a message, reasoning, a tool call, or an engine notice.
struct ItemState: Identifiable {
    enum Kind: Equatable {
        case message
        case reasoning
        case tool(name: String, arg: String)
        case notice(warning: Bool)
    }

    let id: String
    var kind: Kind
    var text = ""
    /// Live output from a running tool.
    var output = ""
    var result: Item.ToolResult?
    var imagePreview: ToolImage?
    var displayImages: [ToolImage] { result?.images ?? (imagePreview.map { [$0] } ?? []) }
    var done = false
    var needsPermission = false
    /// Reported by a running MCP tool.
    var progress: ToolProgress?
    /// For a `Task` call: the subagent's own run, live.
    var subagent: SubagentRun?
    /// Why auto mode let this call run without asking.
    var autoReason: String?
    /// When the engine started and finished it, for "Thought for 2s" and the live line.
    var startedAt: Date?
    var endedAt: Date?
}

/// A subagent's run as it streams in: its items (thinking, tool calls, the report being
/// written) and its speed.
struct SubagentRun {
    var items: [ItemState] = []
    var startedAt = Date()
    var endedAt: Date?
    var tokensPerSec: Double?
    var contextTokens: UInt64?
    var stopping = false

    var steps: Int { items.filter { if case .tool = $0.kind { true } else { false } }.count }

    /// What it's doing right now, for headers and the activity viewer.
    var activity: String {
        guard let last = items.last else { return "Starting" }
        switch last.kind {
        case .tool(let name, let arg):
            let verb = ["Read": "Reading", "Grep": "Searching", "Glob": "Finding", "CodeMap": "Mapping"][name] ?? ToolIcon.title(name)
            return last.done ? "Thinking" : (arg.isEmpty ? verb : "\(verb) \((arg as NSString).lastPathComponent)")
        case .reasoning: return "Thinking"
        case .message: return last.done ? "Reporting" : "Writing the report"
        case .notice: return last.text
        }
    }

    /// Fold one of the subagent's events in.
    mutating func apply(_ event: Event) {
        switch event {
        case .itemStarted(let id, let kind):
            upsert(id) { item in
                switch kind {
                case .message: item.kind = .message
                case .reasoning: item.kind = .reasoning
                case .toolCall(let name, let arg): item.kind = .tool(name: name, arg: arg)
                }
            }
        case .itemDelta(let id, let delta):
            upsert(id) { item in
                switch delta {
                case .text(let t), .reasoning(let t): item.text += t
                case .output(let t): item.output += t
                case .imagePreview(let image, _, _, _): item.imagePreview = image
                }
            }
        case .itemCompleted(let id, let item):
            upsert(id) { state in
                state.imagePreview = nil
                state.done = true
                switch item {
                case .message(let t): state.kind = .message; state.text = t
                case .reasoning(let t): state.kind = .reasoning; state.text = t
                case .toolCall(let r): state.kind = .tool(name: r.name, arg: r.arg); state.result = r
                }
            }
        case .itemsDiscarded(let ids):
            items.removeAll { ids.contains($0.id) }
        case .turnEnded:
            for index in items.indices { items[index].imagePreview = nil }
        case .status(let s):
            tokensPerSec = s.tokensPerSec
            contextTokens = s.contextTokens
        default:
            break
        }
    }

    private mutating func upsert(_ id: String, _ update: (inout ItemState) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            update(&items[i])
        } else {
            var item = ItemState(id: id, kind: .message)
            update(&item)
            items.append(item)
        }
    }
}

struct TurnState: Identifiable {
    let id = UUID()
    /// Assigned by the engine; nil until `turn_started` arrives for a locally echoed prompt.
    var number: UInt64?
    var input: String
    /// Images attached to the message.
    var images: [ToolImage] = []
    /// Messages sent along with `input` as the same turn (queued follow-ups), in order.
    var more: [MessagePart] = []
    /// Background wakes delivered with this turn, ahead of its input (`wakes_delivered`).
    var wakes: [String] = []
    var items: [ItemState] = []
    var end: EndReason?
    var usage: TurnUsage?
    var startedAt: Date?
    var endedAt: Date?
    /// When you sent it from this window: its bubble animates in, like a sent iMessage.
    /// Nil for turns that arrive from a log (history, replay, another window).
    var sentAt: Date?

    var finished: Bool { end != nil }
}

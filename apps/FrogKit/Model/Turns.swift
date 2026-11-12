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
    /// The item's text. For an answer that's streaming, the newest text lives in `live` and this
    /// reads it without registering an observation: the transcript's structure (rows, flows,
    /// equality) reads `text`, and a streamed delta must not re-run all of that (see `LiveText`).
    /// A view that shows the words as they arrive reads `streamedText` instead.
    var text: String {
        get { live?.raw ?? stored }
        set { live = nil; stored = newValue }
    }
    private var stored = ""
    /// The streaming answer's text, while it streams (see `LiveText`). Shared by every copy of
    /// this item, so a row holding an older copy still shows the newest words.
    private(set) var live: LiveText?
    /// The text, observed: for the one view that draws the answer as it streams.
    var streamedText: String { live?.text ?? stored }

    /// Append streamed text. Returns true when that's a change the transcript's structure can
    /// see (the first words, or the first time the item streams), which the caller writes
    /// through the conversation's `turns` as before; otherwise only `live` changed, and only
    /// views reading `streamedText` update.
    mutating func appendStreamed(_ t: String) -> Bool {
        if let live {
            let wasBlank = live.blank
            live.append(t)
            return wasBlank != live.blank
        }
        let box = LiveText(stored)
        box.append(t)
        live = box
        return true
    }

    /// Done streaming: the text goes back to plain storage.
    mutating func settleStreamed() {
        guard let live else { return }
        stored = live.raw
        self.live = nil
    }
    /// Live output from a running tool.
    var output = ""
    var result: Item.ToolResult?
    /// A one-line gist of what the call did, from the engine's side-model ("searched the
    /// engine for where gists flush"). Arrives after the row; the argument stays the fallback.
    var gist: String?
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

    init(id: String, kind: Kind, text: String = "", output: String = "", result: Item.ToolResult? = nil,
         imagePreview: ToolImage? = nil, done: Bool = false, needsPermission: Bool = false,
         progress: ToolProgress? = nil, subagent: SubagentRun? = nil, autoReason: String? = nil,
         startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.kind = kind; stored = text; self.output = output; self.result = result
        self.imagePreview = imagePreview; self.done = done; self.needsPermission = needsPermission
        self.progress = progress; self.subagent = subagent; self.autoReason = autoReason
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// An answer's text while it streams, outside `Conversation.turns`: appending to it doesn't
/// mutate the turns array, so only the answer's own row (which reads `text`, observed) updates
/// on a delta, rather than the transcript's body and every row's equality check (measured: most
/// of streaming's CPU on a 300-turn session).
@Observable
final class LiveText {
    /// Observed: the answer's view reads this.
    private(set) var text: String
    /// The same text, unobserved: what the rest of the app reads.
    @ObservationIgnored private(set) var raw: String
    /// No visible characters yet (a message that hasn't said anything doesn't break its group).
    @ObservationIgnored private(set) var blank: Bool

    init(_ text: String) {
        self.text = text
        raw = text
        blank = text.allSatisfy(\.isWhitespace)
    }

    func append(_ t: String) {
        guard !t.isEmpty else { return }
        raw += t
        if blank, !t.allSatisfy(\.isWhitespace) { blank = false }
        text = raw
    }
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
    /// The model's title for the chapter starting at this turn (`chapter_titled`), when one
    /// arrived; it wins over the rail's heuristic title.
    var chapterTitle: String?

    var finished: Bool { end != nil }

    /// Bumped whenever any turn's `chapterTitle` lands, so a memo of chapter titles knows to
    /// redo them (a title arrives on an earlier turn, which a key on the last turn misses).
    @MainActor static var chapterTitles = 0
}

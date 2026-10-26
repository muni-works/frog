// Swift mirror of crates/frog-engine/src/protocol.rs.
// Events arrive as JSON lines: an envelope {seq, session, created} flattened together with an
// internally tagged `event`. Decoding uses convertFromSnakeCase, so Swift names are camelCase.

import Foundation

// MARK: - Client → engine

enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default` = "default"
    case acceptEdits = "accept-edits"
    case auto = "auto"
    case yolo = "yolo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "Ask"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        case .yolo: "Yolo"
        }
    }

    var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil.and.outline"
        case .auto: "wand.and.sparkles"
        case .yolo: "bolt.fill"
        }
    }

    /// How much the mode allows (`default` asks most, `yolo` never asks). A session's mode
    /// can never be raised above its caller's: rank comparisons decide.
    var rank: Int {
        switch self {
        case .default: 0
        case .acceptEdits: 1
        case .auto: 2
        case .yolo: 3
        }
    }
}

enum Decision: String, Codable, Sendable {
    case allow
    case allowAlways = "allow_always"
    /// This program on paths under the card's prefix, for the rest of the session.
    case allowPrefix = "allow_prefix"
    case deny
}

/// What `Op.continue` tells the model when an app update's drain suspended the turn and the
/// relaunched app picks it back up (the engine's own default when `note` is nil).
let SUSPENDED_NOTE =
    "<resumed after the app updated; your previous turn was suspended; continue>"

enum Op: Encodable, Sendable {
    /// `more`: further messages sent with this one (queued follow-ups), run as the same turn.
    case submit(String, images: [ToolImage] = [], more: [MessagePart] = [])
    case shell(String)
    /// A press on a `Present` actions button; runs a turn with `send` (or the label).
    case act(label: String, send: String)
    case interrupt
    /// Drop the session messages queued in the engine's inbox (sent, not yet taken by a turn).
    case clearInbox
    /// Pick up a turn the app's restart interrupted: the engine runs a turn on the repaired
    /// history with `note` (its own default when nil) as the message.
    case `continue`(note: String? = nil)
    /// `note`, with a deny: the user's words, sent back to the agent.
    case permission(id: String, decision: Decision, note: String? = nil)
    case setMode(Mode)
    case setModel(String)
    case compact(focus: String?)
    case subscribe(after: UInt64)
    case clear
    case setTitle(String)
    /// Answer an MCP elicitation: `accept`, `decline` or `cancel`.
    case elicit(id: String, action: String, content: JSONValue?)
    /// Stop a running subagent (its `Task` tool call id); the parent keeps going.
    case stopSubagent(id: String)
    /// An MCP App calling a tool on its own server.
    case appCall(id: String, server: String, tool: String, arguments: JSONValue)
    /// Open a pane the engine can drive: a shell, or a web preview.
    case paneOpen(kind: PaneKind, cwd: String? = nil, url: String? = nil, cols: Int? = nil, rows: Int? = nil)
    /// Keystrokes (or pasted text) for a terminal pane.
    case paneInput(id: String, data: String)
    case paneResize(id: String, cols: Int, rows: Int)
    case paneClose(id: String)
    /// Something the preview saw: a console line, a failed request, an error, a navigation.
    case paneReport(PaneReport)
    /// The answer to a `paneRequest`.
    case paneReply(call: String, result: JSONValue?, error: String? = nil)
    /// The user clicked an element in inspect mode and mentioned it in the composer.
    case paneMention(id: String, mention: String, context: String? = nil)
    /// What this client can do, sent once after the engine starts.
    case setClientCaps(panes: Bool, ask: Bool = false, sessions: Bool = false)
    /// The answer to a `sessionRequest`: JSON (or text) for the model, or an error.
    case sessionReply(id: String, result: JSONValue?, error: String?)
    /// A message from another session (`from` is its id, or "system"), queued like a submit.
    case deliver(from: String, fromName: String, message: String)
    /// A status-only message from another session: read and logged, no turn starts for it.
    case inform(from: String, fromName: String, message: String)
    /// Answer a `question`: the picked labels, or the user's own words. Neither dismisses it.
    case answer(id: String, choices: [String], other: String?)
    /// Have the model server prefill the conversation now (plus `draft`, the message being
    /// typed), so the next turn starts warm. Fire and forget: nothing comes back.
    case warm(draft: String?)
    /// Graceful stop for an app update: the engine finishes the current step, ends the turn
    /// suspended at the next safe point and acks with `drained`. `deadline` is unix ms.
    case drain(deadline: Int64)
    /// The update was called off; engines already suspended stay that way.
    case drainAbort
    case shutdown

    private enum Key: String, CodingKey {
        case op, text, command, id, decision, mode, spec, focus, after, title
        case action, content, server, tool, arguments, images
        case kind, cwd, url, cols, rows, data, level, message, status, call, result, error, mention, context, panes, draft
        case ask, choices, other, label, send, note, sessions, from, fromName = "from_name", more
        case deadline
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .submit(let text, let images, let more):
            try c.encode("submit", forKey: .op)
            try c.encode(text, forKey: .text)
            if !images.isEmpty { try c.encode(images, forKey: .images) }
            if !more.isEmpty { try c.encode(more, forKey: .more) }
        case .act(let label, let send):
            try c.encode("act", forKey: .op)
            try c.encode(label, forKey: .label)
            if !send.isEmpty { try c.encode(send, forKey: .send) }
        case .shell(let command):
            try c.encode("shell", forKey: .op)
            try c.encode(command, forKey: .command)
        case .interrupt:
            try c.encode("interrupt", forKey: .op)
        case .clearInbox:
            try c.encode("clear_inbox", forKey: .op)
        case .continue(let note):
            try c.encode("continue", forKey: .op)
            try c.encodeIfPresent(note, forKey: .note)
        case .permission(let id, let decision, let note):
            try c.encode("permission", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(decision, forKey: .decision)
            try c.encodeIfPresent(note, forKey: .note)
        case .setMode(let mode):
            try c.encode("set_mode", forKey: .op)
            try c.encode(mode, forKey: .mode)
        case .setModel(let spec):
            try c.encode("set_model", forKey: .op)
            try c.encode(spec, forKey: .spec)
        case .compact(let focus):
            try c.encode("compact", forKey: .op)
            try c.encode(focus, forKey: .focus)
        case .subscribe(let after):
            try c.encode("subscribe", forKey: .op)
            try c.encode(after, forKey: .after)
        case .clear:
            try c.encode("clear", forKey: .op)
        case .setTitle(let title):
            try c.encode("set_title", forKey: .op)
            try c.encode(title, forKey: .title)
        case .elicit(let id, let action, let content):
            try c.encode("elicit", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(content, forKey: .content)
        case .stopSubagent(let id):
            try c.encode("stop_subagent", forKey: .op)
            try c.encode(id, forKey: .id)
        case .appCall(let id, let server, let tool, let arguments):
            try c.encode("app_call", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(server, forKey: .server)
            try c.encode(tool, forKey: .tool)
            try c.encode(arguments, forKey: .arguments)
        case .paneOpen(let kind, let cwd, let url, let cols, let rows):
            try c.encode("pane_open", forKey: .op)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(cols, forKey: .cols)
            try c.encodeIfPresent(rows, forKey: .rows)
        case .paneInput(let id, let data):
            try c.encode("pane_input", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(data, forKey: .data)
        case .paneResize(let id, let cols, let rows):
            try c.encode("pane_resize", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .paneClose(let id):
            try c.encode("pane_close", forKey: .op)
            try c.encode(id, forKey: .id)
        case .paneReport(let r):
            try c.encode("pane_report", forKey: .op)
            try c.encode(r.id, forKey: .id)
            try c.encode(r.kind, forKey: .kind)
            try c.encodeIfPresent(r.level, forKey: .level)
            try c.encode(r.message, forKey: .message)
            try c.encodeIfPresent(r.url, forKey: .url)
            try c.encodeIfPresent(r.status, forKey: .status)
        case .paneReply(let call, let result, let error):
            try c.encode("pane_reply", forKey: .op)
            try c.encode(call, forKey: .call)
            try c.encode(result ?? .null, forKey: .result)
            try c.encodeIfPresent(error, forKey: .error)
        case .paneMention(let id, let mention, let context):
            try c.encode("pane_mention", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(mention, forKey: .mention)
            try c.encodeIfPresent(context, forKey: .context)
        case .setClientCaps(let panes, let ask, let sessions):
            try c.encode("set_client_caps", forKey: .op)
            try c.encode(panes, forKey: .panes)
            if ask { try c.encode(ask, forKey: .ask) }
            if sessions { try c.encode(sessions, forKey: .sessions) }
        case .sessionReply(let id, let result, let error):
            try c.encode("session_reply", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(result, forKey: .result)
            try c.encodeIfPresent(error, forKey: .error)
        case .deliver(let from, let fromName, let message):
            try c.encode("deliver", forKey: .op)
            try c.encode(from, forKey: .from)
            try c.encode(fromName, forKey: .fromName)
            try c.encode(message, forKey: .message)
        case .inform(let from, let fromName, let message):
            try c.encode("inform", forKey: .op)
            try c.encode(from, forKey: .from)
            try c.encode(fromName, forKey: .fromName)
            try c.encode(message, forKey: .message)
        case .answer(let id, let choices, let other):
            try c.encode("answer", forKey: .op)
            try c.encode(id, forKey: .id)
            if !choices.isEmpty { try c.encode(choices, forKey: .choices) }
            try c.encodeIfPresent(other, forKey: .other)
        case .warm(let draft):
            try c.encode("warm", forKey: .op)
            try c.encodeIfPresent(draft, forKey: .draft)
        case .drain(let deadline):
            try c.encode("drain", forKey: .op)
            try c.encode(deadline, forKey: .deadline)
        case .drainAbort:
            try c.encode("drain_abort", forKey: .op)
        case .shutdown:
            try c.encode("shutdown", forKey: .op)
        }
    }
}

// MARK: - Panes

/// A pane the app hosts for the engine: a shell it runs, or a web preview it can read.
enum PaneKind: String, Codable, Sendable {
    case terminal, preview
}

/// One thing the preview saw, reported to the engine so the model can see what it built.
struct PaneReport: Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case console, network, error, navigated, title }
    var id: String
    var kind: Kind
    /// "info", "warn" or "error".
    var level: String?
    var message: String
    var url: String?
    var status: Int?
}

/// The engine asking the preview to do something; answered with `paneReply` within 20s.
struct PaneRequest: Sendable, Equatable {
    var call: String
    var id: String
    /// "read", "click", "type", "screenshot", "navigate", "eval" or "console".
    var action: String
    var args: JSONValue
}

/// A terminal pane's screen: the visible grid as plain text lines and the cursor's [row, col].
struct PaneScreen: Sendable, Equatable {
    var id: String
    var cols: Int
    var rows: Int
    var lines: [String]
    var cursor: [Int]
    var seq: UInt64

    var cursorRow: Int { cursor.first ?? 0 }
    var cursorCol: Int { cursor.count > 1 ? cursor[1] : 0 }
}

// MARK: - Engine → client

struct Todo: Codable, Sendable, Hashable {
    var content: String
    var status: String
}

struct Status: Decodable, Sendable, Equatable {
    var model: String
    var mode: Mode
    var cwd: String
    var messages: Int
    var contextTokens: UInt64?
    var contextWindow: UInt64
    var toolMode: String
    var tier: String
    var tokensPerSec: Double?
    var todos: [Todo]
    /// The model can see images.
    var vision: Bool?
    /// What runs degraded right now (text tool calls, a model nobody picked, auto mode's
    /// classifier down), each with its why. Absent from older engines.
    var degraded: [Degraded]?
}

/// One way a session runs degraded (the engine's `Status.degraded`).
struct Degraded: Decodable, Sendable, Equatable {
    /// "text_tools", "model" or "classifier".
    var kind: String
    /// What's degraded, short and lowercase.
    var what: String
    /// Why, in one line.
    var why: String

    /// The header badge's words: the first thing degraded, and how many more.
    static func badge(_ list: [Degraded]) -> String? {
        guard let first = list.first else { return nil }
        return list.count > 1 ? "\(first.what) +\(list.count - 1)" : first.what
    }

    /// Every one, with its why, a line each (the badge's hover and popover).
    static func detail(_ list: [Degraded]) -> String {
        list.map { "\($0.what): \($0.why)" }.joined(separator: "\n")
    }
}

struct TurnUsage: Decodable, Sendable {
    var contextTokens: UInt64?
    var inputTokens: UInt64
    var outputTokens: UInt64
    /// The part of `inputTokens` read from the provider's cache, and the part written to it.
    /// Absent in older logs (see `cached`).
    var cachedTokens: UInt64?
    var cacheWriteTokens: UInt64?
    var modelCalls: UInt32
    var tokensPerSec: Double?
    /// The model (spec) that ran the turn. Absent in older logs.
    var model: String?
    /// What the turn cost in energy, when the engine measured it (`--energy`).
    var energy: TurnEnergy?
    /// Per-call timing; only its cache counts are read, for logs from before `cachedTokens`.
    var timing: Timing?

    struct Timing: Decodable, Sendable {
        struct Call: Decodable, Sendable { var cachedTokens: UInt64? }
        var calls: [Call]?
    }

    /// Input tokens read from the cache: as the engine totaled them, else summed from the calls.
    var cached: UInt64 {
        min(inputTokens, cachedTokens ?? timing?.calls?.reduce(0) { $0 + ($1.cachedTokens ?? 0) } ?? 0)
    }
    /// Input tokens written to the cache (a subset of the uncached ones).
    var cacheWritten: UInt64 { min(cacheWriteTokens ?? 0, inputTokens - cached) }
    /// Input tokens read fresh, at the full input rate (cache writes included).
    var fresh: UInt64 { inputTokens - cached }
}

/// Watt-hours: the whole Mac above its idle power, and a hosted model's data center, estimated.
struct TurnEnergy: Decodable, Sendable {
    var localWh: Double
    var remoteWh: Double?
    /// The Mac's power at rest that was subtracted, in watts.
    var idleW: Double?
    /// How `remoteWh` was estimated for this model, and where its numbers come from.
    var remoteBasis: String?
    var remoteSource: String?

    var totalWh: Double { localWh + (remoteWh ?? 0) }
    var estimated: Bool { remoteWh != nil }
}

struct EngineError: Decodable, Equatable, Sendable, CustomStringConvertible {
    var type: String
    var status: Int?
    var message: String?

    var description: String {
        switch type {
        case "provider": "Provider error (\(status ?? 0)): \(message ?? "")"
        case "connection": "Couldn't reach the model: \(message ?? "")"
        case "incomplete_stream": "The response stream ended early."
        default: message ?? type
        }
    }
}

enum EndReason: Decodable, Sendable, Equatable {
    case complete, maxTokens, denied, looping, stepLimit, cancelled, suspended
    /// A retry of a call already denied: frog didn't ask again and ended the turn with the denial.
    case blockedOnApproval(String)
    case error(EngineError)

    private enum Key: String, CodingKey { case type, error, denial }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "complete": self = .complete
        case "max_tokens": self = .maxTokens
        case "denied": self = .denied
        case "looping": self = .looping
        case "step_limit": self = .stepLimit
        case "cancelled": self = .cancelled
        case "suspended": self = .suspended
        case "blocked_on_approval": self = .blockedOnApproval((try? c.decode(String.self, forKey: .denial)) ?? "")
        default: self = .error(try c.decode(EngineError.self, forKey: .error))
        }
    }
}

enum ItemKind: Decodable, Sendable, Equatable {
    case message
    case reasoning
    case toolCall(name: String, arg: String)

    private enum Key: String, CodingKey { case type, name, arg }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "tool_call": self = .toolCall(name: try c.decode(String.self, forKey: .name), arg: try c.decode(String.self, forKey: .arg))
        case "reasoning": self = .reasoning
        default: self = .message
        }
    }
}

enum ToolOutcome: String, Decodable, Sendable {
    case ok, error, denied, skipped
}

struct DiffLine: Decodable, Sendable, Hashable {
    enum Kind: String, Decodable, Sendable { case context, add, remove }
    var kind: Kind
    var old: UInt32?
    var new: UInt32?
    var text: String
}

struct Hunk: Decodable, Sendable, Hashable {
    var lines: [DiffLine]
}

struct FileDiff: Decodable, Sendable, Hashable {
    var path: String
    var created: Bool
    var added: UInt32
    var removed: UInt32
    var hunks: [Hunk]
}

enum Item: Decodable, Sendable {
    case message(String)
    case reasoning(String)
    case toolCall(ToolResult)

    struct ToolResult: Decodable, Sendable {
        var name: String
        var arg: String
        var input: JSONValue?
        var outcome: ToolOutcome
        var output: String
        var display: String?
        var diff: FileDiff?
        var diagram: Diagram?
        /// Present's blocks, validated by the engine.
        var present: Present?
        /// Images an MCP tool returned.
        var images: [ToolImage]?
        /// An MCP App to host for this result.
        var app: AppView?
    }

    private enum Key: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "tool_call": self = .toolCall(try ToolResult(from: decoder))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .text))
        default: self = .message(try c.decode(String.self, forKey: .text))
        }
    }
}

enum Delta: Decodable, Sendable {
    case text(String)
    case reasoning(String)
    case output(String)
    case imagePreview(ToolImage, step: UInt64, of: UInt64, imageIndex: Int)

    /// Text that's only appended (what `Conversation` batches).
    var isText: Bool {
        if case .imagePreview = self { false } else { true }
    }

    /// This delta and the next as one, when they're the same kind of text.
    func joined(_ next: Delta) -> Delta? {
        switch (self, next) {
        case (.text(let a), .text(let b)): .text(a + b)
        case (.reasoning(let a), .reasoning(let b)): .reasoning(a + b)
        case (.output(let a), .output(let b)): .output(a + b)
        default: nil
        }
    }

    private enum Key: String, CodingKey { case type, text, image, step, of, imageIndex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if try c.decode(String.self, forKey: .type) == "image_preview" {
            self = .imagePreview(try c.decode(ToolImage.self, forKey: .image), step: try c.decode(UInt64.self, forKey: .step), of: try c.decode(UInt64.self, forKey: .of), imageIndex: try c.decode(Int.self, forKey: .imageIndex))
            return
        }
        let text = try c.decode(String.self, forKey: .text)
        switch try c.decode(String.self, forKey: .type) {
        case "reasoning": self = .reasoning(text)
        case "output": self = .output(text)
        default: self = .text(text)
        }
    }
}

struct ToolImage: Codable, Sendable, Hashable {
    var mime: String
    /// Base64.
    var data: String
}

/// One message the user typed, when several go as one turn (`Op.submit`'s `more`).
struct MessagePart: Codable, Sendable, Hashable {
    var text: String
    var images: [ToolImage] = []

    init(text: String, images: [ToolImage] = []) {
        self.text = text
        self.images = images
    }

    private enum Key: String, CodingKey { case text, images }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        text = try c.decode(String.self, forKey: .text)
        images = try c.decodeIfPresent([ToolImage].self, forKey: .images) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(text, forKey: .text)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
    }
}

/// An MCP App (`ui://` resource): its HTML and the tool's raw result, saved by the engine.
struct AppView: Decodable, Sendable, Hashable {
    var server: String
    var tool: String
    var uri: String
    var html: String
    var result: String
}

/// An MCP server asking the user for input mid-call: a form, or a URL to open.
struct Elicitation: Decodable, Sendable, Identifiable {
    var id: String
    var server: String
    var message: String
    var schema: JSONValue?
    var url: String?
}

/// A session tool call (`ListSessions`, `SendMessage`, `StartSession`) for the app to carry
/// out; answered with `Op.sessionReply`.
struct SessionRequest: Sendable, Equatable {
    var id: String
    /// The tool call waiting on it.
    var item: String
    var tool: String
    var input: JSONValue
}

/// The model asking the user to choose (the `Ask` tool). Answered with `Op.answer`.
struct Question: Decodable, Sendable, Identifiable {
    struct Option: Decodable, Sendable, Hashable {
        var label: String
        var detail: String?
    }
    var id: String
    /// The `Ask` tool call waiting on it.
    var item: String
    var question: String
    var options: [Option]
    var multi: Bool?
    var allowOther: Bool?
}

struct ToolProgress: Sendable, Equatable {
    var progress: Double
    var total: Double?
    var message: String?
}

/// Work reported by the engine. `completed` and `total` are present when the operation has
/// discrete stages, such as capability profiling.
struct EngineProgress: Decodable, Sendable, Equatable {
    var label: String
    var completed: Int?
    var total: Int?

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct PermissionRequest: Decodable, Sendable, Identifiable {
    var id: String
    var item: String
    var name: String
    var arg: String
    var always: String
    /// For Edit/Write: exactly what would change.
    var preview: FileDiff?
    /// Why this one asks when similar calls don't (a command leaving the sandbox).
    var reason: String?
    /// For shell commands: the agent's reason, the trigger, what it touches, and advice.
    var card: ApprovalCard?
}

/// What a shell command's permission prompt shows (engine `ApprovalCard`).
struct ApprovalCard: Codable, Sendable, Equatable {
    struct Touch: Codable, Sendable, Equatable {
        var path: String
        var exists: Bool?
        var dir: Bool?
        var bytes: UInt64?
        var createdHere: Bool?
    }
    var agentReason: String?
    var trigger: String
    var touches: [Touch]?
    var risk: String
    var recommendation: String
    var prefix: String?
    var timeoutSecs: UInt64
}

enum Event: Decodable, Sendable {
    /// `more`: the messages sent along with `input`, in order, each its own bubble.
    case turnStarted(turn: UInt64, input: String, images: [ToolImage], more: [MessagePart])
    case turnEnded(turn: UInt64, reason: EndReason, usage: TurnUsage)
    case itemStarted(id: String, kind: ItemKind)
    case itemCompleted(id: String, item: Item)
    /// A retried model call's partial items (message/reasoning that streamed before the
    /// stream failed); drop them from the turn.
    case itemsDiscarded(ids: [String])
    case permissionResolved(id: String, decision: Decision)
    case compacted(tokensBefore: UInt64, tokensAfter: UInt64)
    case contextPruned(results: Int, tokensBefore: UInt64, tokensAfter: UInt64)
    case modelChanged(String)
    /// The conversation moved to another folder (the agent's `UseFolder`).
    case folderChanged(String)
    case modeChanged(Mode)
    case titled(String)
    case itemDelta(id: String, delta: Delta)
    case permissionRequest(PermissionRequest)
    case progress(EngineProgress)
    /// A `Present` call's closed blocks while its arguments still stream.
    case presentPreview(Present)
    case elicitation(Elicitation)
    case elicitationDone(id: String)
    case question(Question)
    /// Answered or dismissed (an interrupt dismisses it), by any client.
    case questionResolved(id: String)
    case toolProgress(id: String, ToolProgress)
    case appResult(id: String, result: JSONValue?, error: String?)
    /// Auto mode's classifier let tool call `item` run without asking.
    case autoApproved(item: String, reason: String)
    /// How one permission check was decided (rule, classifier, fallback, ask),
    /// for measuring the ask rate; not shown in the transcript.
    case permissionDecision(item: String, layer: String, outcome: String, reason: String, ms: UInt64)
    /// An event from the subagent running as tool call `item`.
    indirect case subagent(item: String, inner: Event)
    case notice(level: String, message: String)
    case error(EngineError)
    case status(Status)
    /// How many background pieces (Monitors, jobs, Tasks) run in the engine now; sent on
    /// every start and end. Live only, never in a log.
    case background(running: Int)
    /// A background piece started: a Task, a shell job (`log` is its output file), a Monitor
    /// or a timer. Durable (logged), like `backgroundDone`.
    case backgroundStarted(id: String, kind: String, label: String, log: String?)
    /// Live output from one (a job's last line, a monitor's poll). Live only.
    case backgroundProgress(id: String, text: String)
    /// One ended: `status` is done, failed, stopped, matched, timeout or
    /// interrupted_by_update; `summary` is the wake the model was given (empty when stopped).
    case backgroundDone(id: String, kind: String, status: String, summary: String)
    /// The wakes waiting for the next turn boundary, in order (each as the model will get
    /// it). Sent when one is parked and when a turn takes them (then empty). Live only.
    case queuedEvents(items: [String])
    /// The wakes turn `turn` opened with, delivered with its input as one batch.
    case wakesDelivered(turn: UInt64, wakes: [String])
    case synced(upto: UInt64)
    case idle
    case paneOpened(id: String, kind: PaneKind, title: String, cwd: String?, url: String?)
    case paneScreen(PaneScreen)
    case paneClosed(id: String, exit: Int?)
    case paneRequest(PaneRequest)
    case sessionRequest(SessionRequest)
    case paneNotice(id: String, level: String, message: String)
    /// A screenshot of the preview the engine kept for a turn (`panes/turn-N.png` in the session
    /// folder), for before/after. Recognized by shape, since its event name isn't fixed yet.
    case paneCheckpoint(turn: UInt64, path: String)
    /// The engine stopped where `drain` asked: it's safe to relaunch. The stopped background
    /// jobs (id, label) are listed for the resumed notice; `inbox` holds delivered messages
    /// that never ran as a turn — re-send them after the restart.
    case drained(stepsDone: Int, jobs: [String], jobLabels: [(String, String)], inbox: [(String, String, String)])
    case unknown(String)
}

struct Envelope: Decodable, Sendable {
    var seq: UInt64
    var session: String
    var created: Int64
    var event: Event

    private enum Key: String, CodingKey { case seq, session, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        seq = try c.decode(UInt64.self, forKey: .seq)
        session = try c.decode(String.self, forKey: .session)
        created = try c.decode(Int64.self, forKey: .created)
        event = try Event(from: decoder)
    }
}

extension Event {
    private enum Key: String, CodingKey {
        case event
        case turn, input, reason, usage, id, kind, item, delta, decision, ids
        case tokensBefore, tokensAfter, results, model, mode, label, level, message, error, upto, title, cwd
        case progress, total, result, inner, present
        case layer, outcome, ms
        case images, more
        case stepsDone = "steps_done", jobs, jobLabels = "job_labels", inbox
        case url, cols, rows, lines, cursor, seq, exit, call, action, args, path, image, tool
        case running
        case status, summary, text, log, items, wakes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "turn_started":
            self = .turnStarted(
                turn: try c.decode(UInt64.self, forKey: .turn),
                input: try c.decode(String.self, forKey: .input),
                images: try c.decodeIfPresent([ToolImage].self, forKey: .images) ?? [],
                more: try c.decodeIfPresent([MessagePart].self, forKey: .more) ?? [])
        case "turn_ended":
            self = .turnEnded(
                turn: try c.decode(UInt64.self, forKey: .turn),
                reason: try c.decode(EndReason.self, forKey: .reason),
                usage: try c.decode(TurnUsage.self, forKey: .usage))
        case "item_started":
            self = .itemStarted(id: try c.decode(String.self, forKey: .id), kind: try c.decode(ItemKind.self, forKey: .kind))
        case "item_completed":
            self = .itemCompleted(id: try c.decode(String.self, forKey: .id), item: try c.decode(Item.self, forKey: .item))
        case "item_delta":
            self = .itemDelta(id: try c.decode(String.self, forKey: .id), delta: try c.decode(Delta.self, forKey: .delta))
        case "items_discarded":
            self = .itemsDiscarded(ids: try c.decode([String].self, forKey: .ids))
        case "permission_resolved":
            self = .permissionResolved(id: try c.decode(String.self, forKey: .id), decision: try c.decode(Decision.self, forKey: .decision))
        case "compacted":
            self = .compacted(
                tokensBefore: try c.decode(UInt64.self, forKey: .tokensBefore),
                tokensAfter: try c.decode(UInt64.self, forKey: .tokensAfter))
        case "context_pruned":
            self = .contextPruned(
                results: try c.decode(Int.self, forKey: .results),
                tokensBefore: try c.decode(UInt64.self, forKey: .tokensBefore),
                tokensAfter: try c.decode(UInt64.self, forKey: .tokensAfter))
        case "model_changed":
            self = .modelChanged(try c.decode(String.self, forKey: .model))
        case "folder_changed":
            self = .folderChanged(try c.decode(String.self, forKey: .cwd))
        case "titled":
            self = .titled(try c.decode(String.self, forKey: .title))
        case "mode_changed":
            self = .modeChanged(try c.decode(Mode.self, forKey: .mode))
        case "permission_request":
            self = .permissionRequest(try PermissionRequest(from: decoder))
        case "progress":
            self = .progress(try EngineProgress(from: decoder))
        case "present_preview":
            self = .presentPreview(try c.decode(Present.self, forKey: .present))
        case "elicitation":
            self = .elicitation(try Elicitation(from: decoder))
        case "question":
            self = .question(try Question(from: decoder))
        case "question_resolved":
            self = .questionResolved(id: try c.decode(String.self, forKey: .id))
        case "elicitation_done":
            self = .elicitationDone(id: try c.decode(String.self, forKey: .id))
        case "tool_progress":
            self = .toolProgress(
                id: try c.decode(String.self, forKey: .id),
                ToolProgress(
                    progress: try c.decode(Double.self, forKey: .progress),
                    total: try c.decodeIfPresent(Double.self, forKey: .total),
                    message: try c.decodeIfPresent(String.self, forKey: .message)))
        case "auto_approved":
            self = .autoApproved(item: try c.decode(String.self, forKey: .item), reason: try c.decode(String.self, forKey: .reason))
        case "permission_decision":
            let item = try c.decode(String.self, forKey: .item)
            let layer = try c.decode(String.self, forKey: .layer)
            let outcome = try c.decode(String.self, forKey: .outcome)
            let reason = try c.decode(String.self, forKey: .reason)
            let ms: UInt64 = try c.decodeIfPresent(UInt64.self, forKey: .ms) ?? 0
            self = .permissionDecision(item: item, layer: layer, outcome: outcome, reason: reason, ms: ms)
        case "subagent":
            self = .subagent(item: try c.decode(String.self, forKey: .item), inner: try c.decode(Event.self, forKey: .inner))
        case "app_result":
            self = .appResult(
                id: try c.decode(String.self, forKey: .id),
                result: try c.decodeIfPresent(JSONValue.self, forKey: .result),
                error: try c.decodeIfPresent(String.self, forKey: .error))
        case "notice":
            self = .notice(level: try c.decode(String.self, forKey: .level), message: try c.decode(String.self, forKey: .message))
        case "error":
            self = .error(try c.decode(EngineError.self, forKey: .error))
        case "status":
            self = .status(try Status(from: decoder))
        case "background":
            self = .background(running: try c.decode(Int.self, forKey: .running))
        case "background_started":
            self = .backgroundStarted(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                log: try c.decodeIfPresent(String.self, forKey: .log))
        case "background_progress":
            self = .backgroundProgress(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "queued_events":
            self = .queuedEvents(items: try c.decodeIfPresent([String].self, forKey: .items) ?? [])
        case "wakes_delivered":
            self = .wakesDelivered(
                turn: try c.decode(UInt64.self, forKey: .turn),
                wakes: try c.decodeIfPresent([String].self, forKey: .wakes) ?? [])
        case "background_done":
            self = .backgroundDone(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                status: try c.decode(String.self, forKey: .status),
                summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
        case "synced":
            self = .synced(upto: try c.decode(UInt64.self, forKey: .upto))
        case "idle":
            self = .idle
        case "pane_opened":
            self = .paneOpened(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(PaneKind.self, forKey: .kind),
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                url: try c.decodeIfPresent(String.self, forKey: .url))
        case "pane_screen":
            self = .paneScreen(PaneScreen(
                id: try c.decode(String.self, forKey: .id),
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                lines: try c.decode([String].self, forKey: .lines),
                cursor: try c.decodeIfPresent([Int].self, forKey: .cursor) ?? [0, 0],
                seq: try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0))
        case "pane_closed":
            self = .paneClosed(id: try c.decode(String.self, forKey: .id), exit: try c.decodeIfPresent(Int.self, forKey: .exit))
        case "pane_request":
            self = .paneRequest(PaneRequest(
                call: try c.decode(String.self, forKey: .call),
                id: try c.decode(String.self, forKey: .id),
                action: try c.decode(String.self, forKey: .action),
                args: try c.decodeIfPresent(JSONValue.self, forKey: .args) ?? .object([:])))
        case "session_request":
            self = .sessionRequest(SessionRequest(
                id: try c.decode(String.self, forKey: .id),
                item: try c.decodeIfPresent(String.self, forKey: .item) ?? "",
                tool: try c.decode(String.self, forKey: .tool),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])))
        case "pane_notice":
            self = .paneNotice(
                id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                level: try c.decodeIfPresent(String.self, forKey: .level) ?? "info",
                message: try c.decode(String.self, forKey: .message))
        case "drained":
            func triples(_ raw: [JSONValue]) -> [(String, String, String)] {
                raw.compactMap { v in
                    if case .array(let parts) = v, parts.count >= 3,
                       case .string(let a) = parts[0], case .string(let b) = parts[1], case .string(let c) = parts[2] {
                        return (a, b, c)
                    }
                    return nil
                }
            }
            func pairs(_ raw: [JSONValue]) -> [(String, String)] {
                raw.compactMap { v in
                    if case .array(let parts) = v, parts.count >= 2,
                       case .string(let a) = parts[0], case .string(let b) = parts[1] {
                        return (a, b)
                    }
                    return nil
                }
            }
            func strings(_ raw: [JSONValue]) -> [String] {
                raw.compactMap { v in if case .string(let s) = v { return s } else { return nil } }
            }
            self = .drained(
                stepsDone: try c.decodeIfPresent(Int.self, forKey: .stepsDone) ?? 0,
                jobs: (try? c.decodeIfPresent([JSONValue].self, forKey: .jobs)).flatMap(strings) ?? [],
                jobLabels: (try? c.decodeIfPresent([JSONValue].self, forKey: .jobLabels)).flatMap(pairs) ?? [],
                inbox: (try? c.decodeIfPresent([JSONValue].self, forKey: .inbox)).flatMap(triples) ?? [])
        default:
            // A checkpoint screenshot record, whatever it's called: a turn and a PNG path.
            if let turn = try? c.decodeIfPresent(UInt64.self, forKey: .turn),
               let path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? (try? c.decodeIfPresent(String.self, forKey: .image)),
               path.lowercased().hasSuffix(".png") {
                self = .paneCheckpoint(turn: turn, path: path)
            } else {
                self = .unknown(name)
            }
        }
    }
}

/// Arbitrary JSON (tool inputs, MCP results).
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From JSONSerialization output (`[String: Any]`, `NSNumber`, …).
    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    /// For JSONSerialization / JavaScript.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Numbers as integers when they are (counts, ids), else as doubles.
    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var int: Int? {
        if case .number(let n) = self { return n == n.rounded() && abs(n) < 1e15 ? Int(n) : nil }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - CLI listings

/// An Agent Skill (`frog --skills --json`).
struct SkillInfo: Decodable, Sendable, Hashable {
    var name: String
    var description: String
    var project: Bool
}

struct SessionInfo: Codable, Sendable, Identifiable, Hashable {
    struct ForkPoint: Codable, Sendable, Hashable {
        var session: String
        var seq: UInt64
    }

    /// How the last turn ended ("open", "complete", "stopped", "failed"), when the engine
    /// knows (see `frog --sessions --json`).
    enum End: String, Codable, Sendable, Hashable {
        case open, complete, stopped, failed
    }

    var id: String
    var modified: Int64
    var created: Int64
    var model: String
    var firstInput: String?
    var title: String?
    var end: End?
    var forkedFrom: ForkPoint?
    /// The folder it works in (the chat folder for plain chats).
    var cwd: String?

    var displayTitle: String {
        let t = (title ?? firstInput ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.titleLine(t) ?? "Untitled"
    }
    var folder: URL? { cwd.map { URL(fileURLWithPath: $0) } }
    var isChat: Bool { folder.map(FrogPaths.isChat) ?? false }

    var modifiedDate: Date { Date(timeIntervalSince1970: Double(modified) / 1000) }

    /// The line to title a session from: the first paragraph that isn't boilerplate a prompt
    /// carries for its agent (worktree rules, resume notes — they run to the next blank line).
    /// When every paragraph opens with boilerplate, the task may share its paragraph (a
    /// one-line note with the task right under it), so the first plain line titles it.
    static func titleLine(_ text: String) -> String? {
        func boilerplate(_ line: String) -> Bool {
            line.hasPrefix("RULES:") || line.hasPrefix("You were stopped")
        }
        func lines(_ paragraph: String) -> [String] {
            paragraph.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs where !boilerplate(lines(paragraph).first ?? "") {
            if let first = lines(paragraph).first { return first }
        }
        for paragraph in paragraphs {
            if let line = lines(paragraph).first(where: { !boilerplate($0) }) { return line }
        }
        return nil
    }
}

struct Rewound: Decodable, Sendable {
    var session: String
    var restored: [String]
}

struct ModelEntry: Codable, Sendable, Identifiable, Hashable {
    struct Caps: Codable, Sendable, Hashable {
        var nativeTools: Bool
        var textTools: Bool
        var jsonMode: Bool
        var abstains: Bool
        var paramsB: Double?
    }

    var spec: String
    var provider: String
    var model: String
    var source: String
    var caps: Caps?
    var tier: String
    var toolMode: String
    /// The provider's catalog entry, for models turned on from a provider.
    var info: CatalogModel?

    var id: String { spec }
}

/// A model a provider offers, with what's worth knowing to pick it.
struct CatalogModel: Codable, Sendable, Hashable, Identifiable {
    var spec: String
    var provider: String
    var id: String
    var name: String
    var context: UInt64?
    var maxOutput: UInt64?
    var inputs: [String]
    var reasoning: Bool
    var tools: Bool
    /// Dollars per million tokens.
    var costIn: Double?
    var costOut: Double?
    /// Dollars per million cached input tokens read, and written to the cache, when listed.
    var costCacheRead: Double?
    var costCacheWrite: Double?
    /// Shown in the model list (only in `--catalog` output).
    var enabled: Bool?

    var vision: Bool { inputs.contains("image") }
}

/// A provider: a preset gateway or API, a local server, or one you added.
struct ProviderInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var baseUrl: String
    var local: Bool
    var custom: Bool
    /// "keychain" or "env" when it has a key.
    var key: String?
    var keyUrl: String
    var connected: Bool
    /// Where it sorts: This Mac, your servers, frog cloud, other clouds. Older engines omit it.
    var rank: Int? = nil
    /// Always listed and never removable (frog cloud).
    var pinned: Bool? = nil

    /// `id` with old names folded in (`tang` → `local`, `frog-api` → `cloud`, …).
    var canonicalID: String { ProviderID.canonical(id) }
    var isFrogCloud: Bool { canonicalID == ProviderID.cloud }
    /// "This Mac", "frog cloud", or the provider's own name.
    var displayName: String { ProviderID.displayName(id) ?? name }

    /// The shared order when the engine doesn't say: This Mac, your servers, frog cloud, other clouds.
    var sortRank: Int {
        if let rank { return rank }
        if canonicalID == ProviderID.local || (local && !custom) { return 0 }
        if custom { return 1 }
        if isFrogCloud { return 2 }
        return 3
    }

    /// Providers in the shared order (stable within a rank).
    static func sorted(_ list: [ProviderInfo]) -> [ProviderInfo] {
        list.enumerated().sorted { a, b in
            (a.element.sortRank, a.offset) < (b.element.sortRank, b.offset)
        }.map(\.element)
    }
}

/// Provider ids say where a model runs. Old ids may still be in saved state, so compare
/// through `canonical`.
enum ProviderID {
    /// frog's engine on this Mac ("This Mac", powered by tang).
    static let local = "local"
    /// frog's hosted service ("frog cloud").
    static let cloud = "cloud"
    /// The model frog cloud always lists, even signed out.
    static let cloudModel = "cloud/qwen3-coder-next"
    static let localName = "This Mac"
    static let cloudName = "frog cloud"

    static func canonical(_ id: String) -> String {
        switch id {
        case "tang": local
        case "frog-api", "frog", "tang-cloud", "zest": cloud
        default: id
        }
    }

    static func same(_ a: String, _ b: String) -> Bool { canonical(a) == canonical(b) }

    /// The fixed names of frog's own providers; nil for anyone else's.
    static func displayName(_ id: String) -> String? {
        switch canonical(id) {
        case local: localName
        case cloud: cloudName
        default: nil
        }
    }

    /// A spec with its provider part folded: "tang/x" → "local/x".
    static func canonicalSpec(_ spec: String) -> String {
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return spec }
        return canonical(parts[0]) + "/" + parts[1]
    }

    /// The provider part of a spec, folded: "tang/x" → "local".
    static func of(spec: String) -> String {
        canonical(String(spec.split(separator: "/", maxSplits: 1).first ?? ""))
    }
}

extension JSONDecoder {
    static let frog: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension CatalogModel {
    /// "$3 / $15 per M tokens", or nil when unknown.
    var price: String? {
        guard let i = costIn, let o = costOut else { return nil }
        if i == 0, o == 0 { return "Free" }
        return "\(Self.dollars(i)) in · \(Self.dollars(o)) out per M"
    }

    var contextLabel: String? {
        context.map { $0 >= 1_000_000 ? String(format: "%gM", Double($0) / 1_000_000) : "\($0 / 1000)k" }
    }

    private static func dollars(_ v: Double) -> String {
        v < 1 ? String(format: "$%.2f", v) : String(format: "$%g", (v * 100).rounded() / 100)
    }
}

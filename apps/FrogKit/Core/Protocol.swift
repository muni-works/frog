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
}

enum Decision: String, Codable, Sendable {
    case allow
    case allowAlways = "allow_always"
    case deny
}

enum Op: Encodable, Sendable {
    case submit(String, images: [ToolImage] = [])
    case shell(String)
    /// A press on a `Present` actions button; runs a turn with `send` (or the label).
    case act(label: String, send: String)
    case interrupt
    case permission(id: String, decision: Decision)
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
    case setClientCaps(panes: Bool, ask: Bool = false)
    /// Answer a `question`: the picked labels, or the user's own words. Neither dismisses it.
    case answer(id: String, choices: [String], other: String?)
    /// Have the model server prefill the conversation now (plus `draft`, the message being
    /// typed), so the next turn starts warm. Fire and forget: nothing comes back.
    case warm(draft: String?)
    case shutdown

    private enum Key: String, CodingKey {
        case op, text, command, id, decision, mode, spec, focus, after, title
        case action, content, server, tool, arguments, images
        case kind, cwd, url, cols, rows, data, level, message, status, call, result, error, mention, context, panes, draft
        case ask, choices, other, label, send
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .submit(let text, let images):
            try c.encode("submit", forKey: .op)
            try c.encode(text, forKey: .text)
            if !images.isEmpty { try c.encode(images, forKey: .images) }
        case .act(let label, let send):
            try c.encode("act", forKey: .op)
            try c.encode(label, forKey: .label)
            if !send.isEmpty { try c.encode(send, forKey: .send) }
        case .shell(let command):
            try c.encode("shell", forKey: .op)
            try c.encode(command, forKey: .command)
        case .interrupt:
            try c.encode("interrupt", forKey: .op)
        case .permission(let id, let decision):
            try c.encode("permission", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(decision, forKey: .decision)
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
        case .setClientCaps(let panes, let ask):
            try c.encode("set_client_caps", forKey: .op)
            try c.encode(panes, forKey: .panes)
            if ask { try c.encode(ask, forKey: .ask) }
        case .answer(let id, let choices, let other):
            try c.encode("answer", forKey: .op)
            try c.encode(id, forKey: .id)
            if !choices.isEmpty { try c.encode(choices, forKey: .choices) }
            try c.encodeIfPresent(other, forKey: .other)
        case .warm(let draft):
            try c.encode("warm", forKey: .op)
            try c.encodeIfPresent(draft, forKey: .draft)
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

struct Status: Decodable, Sendable {
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
}

struct TurnUsage: Decodable, Sendable {
    var contextTokens: UInt64?
    var inputTokens: UInt64
    var outputTokens: UInt64
    var modelCalls: UInt32
    var tokensPerSec: Double?
    /// The model (spec) that ran the turn. Absent in older logs.
    var model: String?
    /// What the turn cost in energy, when the engine measured it (`--energy`).
    var energy: TurnEnergy?
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

struct EngineError: Decodable, Sendable, CustomStringConvertible {
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

enum EndReason: Decodable, Sendable {
    case complete, maxTokens, denied, looping, stepLimit, cancelled
    case error(EngineError)

    private enum Key: String, CodingKey { case type, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "complete": self = .complete
        case "max_tokens": self = .maxTokens
        case "denied": self = .denied
        case "looping": self = .looping
        case "step_limit": self = .stepLimit
        case "cancelled": self = .cancelled
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
}

enum Event: Decodable, Sendable {
    case turnStarted(turn: UInt64, input: String, images: [ToolImage])
    case turnEnded(turn: UInt64, reason: EndReason, usage: TurnUsage)
    case itemStarted(id: String, kind: ItemKind)
    case itemCompleted(id: String, item: Item)
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
    case progress(String)
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
    /// An event from the subagent running as tool call `item`.
    indirect case subagent(item: String, inner: Event)
    case notice(level: String, message: String)
    case error(EngineError)
    case status(Status)
    case synced(upto: UInt64)
    case idle
    case paneOpened(id: String, kind: PaneKind, title: String, cwd: String?, url: String?)
    case paneScreen(PaneScreen)
    case paneClosed(id: String, exit: Int?)
    case paneRequest(PaneRequest)
    case paneNotice(id: String, level: String, message: String)
    /// A screenshot of the preview the engine kept for a turn (`panes/turn-N.png` in the session
    /// folder), for before/after. Recognized by shape, since its event name isn't fixed yet.
    case paneCheckpoint(turn: UInt64, path: String)
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
        case turn, input, reason, usage, id, kind, item, delta, decision
        case tokensBefore, tokensAfter, results, model, mode, label, level, message, error, upto, title, cwd
        case progress, total, result, inner, present
        case images
        case url, cols, rows, lines, cursor, seq, exit, call, action, args, path, image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "turn_started":
            self = .turnStarted(
                turn: try c.decode(UInt64.self, forKey: .turn),
                input: try c.decode(String.self, forKey: .input),
                images: try c.decodeIfPresent([ToolImage].self, forKey: .images) ?? [])
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
            self = .progress(try c.decode(String.self, forKey: .label))
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
        case "pane_notice":
            self = .paneNotice(
                id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                level: try c.decodeIfPresent(String.self, forKey: .level) ?? "info",
                message: try c.decode(String.self, forKey: .message))
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

    var id: String
    var modified: Int64
    var created: Int64
    var model: String
    var firstInput: String?
    var title: String?
    var forkedFrom: ForkPoint?
    /// The folder it works in (the chat folder for plain chats).
    var cwd: String?

    var displayTitle: String {
        let t = (title ?? firstInput ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.split(separator: "\n").first.map(String.init) ?? "Untitled"
    }
    var folder: URL? { cwd.map { URL(fileURLWithPath: $0) } }
    var isChat: Bool { folder.map(FrogPaths.isChat) ?? false }

    var modifiedDate: Date { Date(timeIntervalSince1970: Double(modified) / 1000) }
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

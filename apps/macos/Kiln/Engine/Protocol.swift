// Swift mirror of crates/kiln-engine/src/protocol.rs.
// Events arrive as JSON lines: an envelope {seq, session, created} flattened together with an
// internally tagged `event`. Decoding uses convertFromSnakeCase, so Swift names are camelCase.

import Foundation

// MARK: - Client → engine

enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default` = "default"
    case acceptEdits = "accept-edits"
    case yolo = "yolo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "Ask"
        case .acceptEdits: "Accept Edits"
        case .yolo: "Yolo"
        }
    }

    var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil.and.outline"
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
    case submit(String)
    case shell(String)
    case interrupt
    case permission(id: String, decision: Decision)
    case setMode(Mode)
    case setModel(String)
    case compact(focus: String?)
    case subscribe(after: UInt64)
    case clear
    case setTitle(String)
    case shutdown

    private enum Key: String, CodingKey {
        case op, text, command, id, decision, mode, spec, focus, after, title
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .submit(let text):
            try c.encode("submit", forKey: .op)
            try c.encode(text, forKey: .text)
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
        case .shutdown:
            try c.encode("shutdown", forKey: .op)
        }
    }
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
}

struct TurnUsage: Decodable, Sendable {
    var contextTokens: UInt64?
    var inputTokens: UInt64
    var outputTokens: UInt64
    var modelCalls: UInt32
    var tokensPerSec: Double?
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

    private enum Key: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let text = try c.decode(String.self, forKey: .text)
        switch try c.decode(String.self, forKey: .type) {
        case "reasoning": self = .reasoning(text)
        case "output": self = .output(text)
        default: self = .text(text)
        }
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
}

enum Event: Sendable {
    case turnStarted(turn: UInt64, input: String)
    case turnEnded(turn: UInt64, reason: EndReason, usage: TurnUsage)
    case itemStarted(id: String, kind: ItemKind)
    case itemCompleted(id: String, item: Item)
    case permissionResolved(id: String, decision: Decision)
    case compacted(tokensBefore: UInt64, tokensAfter: UInt64)
    case contextPruned(results: Int, tokensBefore: UInt64, tokensAfter: UInt64)
    case modelChanged(String)
    case modeChanged(Mode)
    case titled(String)
    case itemDelta(id: String, delta: Delta)
    case permissionRequest(PermissionRequest)
    case progress(String)
    case notice(level: String, message: String)
    case error(EngineError)
    case status(Status)
    case synced(upto: UInt64)
    case idle
    case unknown(String)
}

struct Envelope: Decodable, Sendable {
    var seq: UInt64
    var session: String
    var created: Int64
    var event: Event

    private enum Key: String, CodingKey {
        case seq, session, created, event
        case turn, input, reason, usage, id, kind, item, delta, decision
        case tokensBefore, tokensAfter, results, model, mode, label, level, message, error, upto, title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        seq = try c.decode(UInt64.self, forKey: .seq)
        session = try c.decode(String.self, forKey: .session)
        created = try c.decode(Int64.self, forKey: .created)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "turn_started":
            event = .turnStarted(turn: try c.decode(UInt64.self, forKey: .turn), input: try c.decode(String.self, forKey: .input))
        case "turn_ended":
            event = .turnEnded(
                turn: try c.decode(UInt64.self, forKey: .turn),
                reason: try c.decode(EndReason.self, forKey: .reason),
                usage: try c.decode(TurnUsage.self, forKey: .usage))
        case "item_started":
            event = .itemStarted(id: try c.decode(String.self, forKey: .id), kind: try c.decode(ItemKind.self, forKey: .kind))
        case "item_completed":
            event = .itemCompleted(id: try c.decode(String.self, forKey: .id), item: try c.decode(Item.self, forKey: .item))
        case "item_delta":
            event = .itemDelta(id: try c.decode(String.self, forKey: .id), delta: try c.decode(Delta.self, forKey: .delta))
        case "permission_resolved":
            event = .permissionResolved(id: try c.decode(String.self, forKey: .id), decision: try c.decode(Decision.self, forKey: .decision))
        case "compacted":
            event = .compacted(
                tokensBefore: try c.decode(UInt64.self, forKey: .tokensBefore),
                tokensAfter: try c.decode(UInt64.self, forKey: .tokensAfter))
        case "context_pruned":
            event = .contextPruned(
                results: try c.decode(Int.self, forKey: .results),
                tokensBefore: try c.decode(UInt64.self, forKey: .tokensBefore),
                tokensAfter: try c.decode(UInt64.self, forKey: .tokensAfter))
        case "model_changed":
            event = .modelChanged(try c.decode(String.self, forKey: .model))
        case "titled":
            event = .titled(try c.decode(String.self, forKey: .title))
        case "mode_changed":
            event = .modeChanged(try c.decode(Mode.self, forKey: .mode))
        case "permission_request":
            event = .permissionRequest(try PermissionRequest(from: decoder))
        case "progress":
            event = .progress(try c.decode(String.self, forKey: .label))
        case "notice":
            event = .notice(level: try c.decode(String.self, forKey: .level), message: try c.decode(String.self, forKey: .message))
        case "error":
            event = .error(try c.decode(EngineError.self, forKey: .error))
        case "status":
            event = .status(try Status(from: decoder))
        case "synced":
            event = .synced(upto: try c.decode(UInt64.self, forKey: .upto))
        case "idle":
            event = .idle
        default:
            event = .unknown(name)
        }
    }
}

/// Arbitrary JSON (tool inputs).
enum JSONValue: Decodable, Sendable, Hashable {
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

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - CLI listings

struct SessionInfo: Decodable, Sendable, Identifiable, Hashable {
    struct ForkPoint: Decodable, Sendable, Hashable {
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

    var displayTitle: String { title ?? firstInput ?? "Untitled" }

    var modifiedDate: Date { Date(timeIntervalSince1970: Double(modified) / 1000) }
}

struct Rewound: Decodable, Sendable {
    var session: String
    var restored: [String]
}

struct ModelEntry: Decodable, Sendable, Identifiable, Hashable {
    struct Caps: Decodable, Sendable, Hashable {
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

    var id: String { spec }
}

extension JSONDecoder {
    static let kiln: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

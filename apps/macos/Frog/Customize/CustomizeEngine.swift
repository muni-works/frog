import Foundation

/// The engine's Customize report (docs/customize-api.md, from the customize-engine work):
/// `frog --customize --json` in the project folder, and `frog --customize-change '<change>'
/// --json`, which answers with the report as it is after the change. An engine without it
/// fails the call, and the store falls back to what today's engine answers (`--skills`,
/// `--mcp`, `--setup`, the note files), with no figures and no switches.
struct CustomizeReport: Decodable, Equatable {
    struct Use: Decodable, Equatable {
        struct Last: Decodable, Equatable { var at: String?; var session: String?; var title: String? }
        var count: Int
        var days: [Int]
        var last: Last?
    }

    struct Skill: Decodable, Equatable {
        var id: String
        var name: String
        var description: String
        var scope: String
        var source: String?
        var path: String?
        var on: Bool
        var tokens: Int?
        var tokensIfOn: Int?
        var fullTokens: Int?
        var shadowedBy: String?
        var use: Use?
    }

    struct Tool: Decodable, Equatable {
        var name: String
        var exposed: String
        var description: String?
        var state: String
        var why: String?
        var readOnly: Bool?
        var tokens: Int?
        var tokensIfOn: Int?
    }

    struct Connection: Decodable, Equatable {
        var name: String
        var scope: String
        var source: String?
        var on: Bool
        var state: String
        var error: String?
        var waiting: String?
        var tokens: Int?
        var tokensIfAllOn: Int?
        var tools: [Tool]
        var use: Use?
    }

    struct RulesFile: Decodable, Equatable {
        var path: String
        var scope: String
        var tokens: Int?
    }

    struct Note: Decodable, Equatable {
        var id: String
        var scope: String
        var created: String?
        var session: String?
        var title: String?
        var text: String
        var path: String
        var tokens: Int?
    }

    struct Skills: Decodable, Equatable { var tokens: Int?; var budgetTokens: Int?; var namesOnly: Bool?; var items: [Skill] }
    struct Connections: Decodable, Equatable { var tokens: Int?; var deferred: Bool?; var items: [Connection] }
    struct Rules: Decodable, Equatable { var tokens: Int?; var files: [RulesFile] }
    struct Memory: Decodable, Equatable { var tokens: Int?; var omitted: Int?; var notes: [Note] }

    var project: String?
    var tokens: Int?
    var skills: Skills
    var connections: Connections
    var rules: Rules
    var memory: Memory

    // MARK: Into the pages' shapes

    var pageSkills: [CustomizeSkill] {
        skills.items.filter { $0.shadowedBy == nil }.map { s in
            var k = CustomizeSkill(name: s.name, description: s.description,
                                   path: s.path ?? (s.id.hasPrefix("frog-builtin:") ? s.id : "frog-builtin:\(s.name)"),
                                   project: s.scope == "project")
            k.engineID = s.id
            k.on = s.on
            k.tokensPerTurn = s.tokens
            k.fullTokens = s.fullTokens
            k.uses = s.use?.days
            k.lastUsed = s.use?.last?.title
            return k
        }
    }

    var pageConnections: [CustomizeConnection] {
        connections.items.map { c in
            let squares: [ToolSquares.Square] = c.tools.map { t in
                let state: ToolSquares.State = t.state == "on" ? .on : t.state == "withheld" ? .withheld : .off
                return .init(tool: t.name, state: state, reason: t.why, exposed: t.exposed)
            }
            return CustomizeConnection(name: c.name, state: CustomizeConnection.State(engine: c.state), error: c.error,
                                       fromProject: c.source == "project", squares: squares, on: c.on, tokens: c.tokens,
                                       calls: c.use?.count)
        }
    }

    func pageNotes() -> [MemoryNote] {
        let iso = ISO8601DateFormatter()
        return memory.notes.map { n in
            MemoryNote(id: n.id, created: n.created.flatMap { iso.date(from: $0) }, scope: n.scope == "project" ? .project : .everywhere,
                       body: n.text, url: URL(fileURLWithPath: n.path), from: n.title)
        }
    }
}

/// One change the engine makes, as JSON for `--customize-change`.
enum CustomizeChange: Equatable {
    case skill(id: String, on: Bool)
    case connection(name: String, on: Bool)
    case tool(exposed: String, on: Bool)

    var json: String {
        let obj: [String: Any] = switch self {
        case .skill(let id, let on): ["change": "skill", "id": id, "on": on]
        case .connection(let name, let on): ["change": "connection", "name": name, "on": on]
        case .tool(let exposed, let on): ["change": "tool", "exposed": exposed, "on": on]
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A connection as the page draws it, from the engine's report or, on an older engine, from
/// `frog --mcp --json`.
struct CustomizeConnection: Identifiable, Hashable {
    enum State: Hashable {
        case connected, connecting, needsSignIn, declined, failed, off, unknown
        init(engine: String) {
            switch engine {
            case "connected": self = .connected
            case "connecting": self = .connecting
            case "needs_sign_in": self = .needsSignIn
            case "declined": self = .declined
            case "failed": self = .failed
            case "off": self = .off
            default: self = .unknown
            }
        }
    }

    let name: String
    var state: State
    var error: String?
    /// Came with the project's .mcp.json.
    var fromProject: Bool
    var squares: [ToolSquares.Square]
    /// Nil on an engine that can't switch connections.
    var on: Bool? = nil
    var tokens: Int? = nil
    /// Calls in the last 30 days.
    var calls: Int? = nil
    var id: String { name }
    var wantsSignIn: Bool { state == .needsSignIn || state == .declined }

    init(name: String, state: State, error: String?, fromProject: Bool, squares: [ToolSquares.Square],
         on: Bool? = nil, tokens: Int? = nil, calls: Int? = nil) {
        self.name = name
        self.state = state
        self.error = error
        self.fromProject = fromProject
        self.squares = squares
        self.on = on
        self.tokens = tokens
        self.calls = calls
    }

    /// From today's `frog --mcp --json`.
    init(_ s: MCPStatus, fromProject: Bool) {
        let state: State = s.connected ? .connected : s.needsAuth == true ? (s.declined == true ? .declined : .needsSignIn) : .failed
        self.init(name: s.name, state: state, error: s.error, fromProject: fromProject, squares: ConnectionsPage.squares(s))
    }
}

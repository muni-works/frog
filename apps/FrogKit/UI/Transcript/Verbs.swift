// frog — generated from docs/design/transcript/verbs.json by design/generate.mjs; edit the JSON, not this file.

/// The transcript's verbs (docs/design/transcript/spec.md, "Lines"): one table for the Mac and the
/// web, keyed by the engine's tool name, lowercased (aliases included).
enum Verbs {
    /// How a line sets what the step acted on.
    enum Object: String {
        /// Mono: a command's first line.
        case command
        /// Mono: the path as the tool was given it.
        case path
        /// Mono: what was searched for.
        case pattern
        /// The URL's host.
        case host
        /// The argument as words.
        case text
        /// Mono: the tool's own name, for a tool this table doesn't know.
        case tool
        /// The verb is the whole line.
        case none

        /// Code, paths, commands and tool names are mono; words aren't.
        var mono: Bool { [.command, .path, .pattern, .tool].contains(self) }
    }

    struct Look: Equatable {
        let tool: String
        /// A running step's verb.
        let live: String
        /// A finished step's verb.
        let past: String
        /// A finished step's verb when it created the file (Write).
        let created: String?
        let object: Object
    }

    /// A failed step's verb, set in `warn`.
    static let failed = "Failed"
    /// A denied step's verb, and its result.
    static let denied = "Didn't run"
    static let deniedResult = "you said no"

    /// A tool the table doesn't know (an MCP call).
    static let unknownLive = "Calling"
    static let unknownPast = "Called"

    static let table: [String: Look] = [
        "bash": Look(tool: "Bash", live: "Running", past: "Ran", created: nil, object: .command),
        "!": Look(tool: "Bash", live: "Running", past: "Ran", created: nil, object: .command),
        "read": Look(tool: "Read", live: "Reading", past: "Read", created: nil, object: .path),
        "edit": Look(tool: "Edit", live: "Editing", past: "Edited", created: nil, object: .path),
        "multiedit": Look(tool: "Edit", live: "Editing", past: "Edited", created: nil, object: .path),
        "write": Look(tool: "Write", live: "Writing", past: "Wrote", created: "Created", object: .path),
        "grep": Look(tool: "Grep", live: "Searching", past: "Searched", created: nil, object: .pattern),
        "glob": Look(tool: "Glob", live: "Searching", past: "Searched", created: nil, object: .pattern),
        "codemap": Look(tool: "CodeMap", live: "Mapping", past: "Mapped", created: nil, object: .path),
        "webfetch": Look(tool: "WebFetch", live: "Fetching", past: "Fetched", created: nil, object: .host),
        "websearch": Look(tool: "WebSearch", live: "Searching the web for", past: "Searched the web for", created: nil, object: .text),
        "task": Look(tool: "Task", live: "Delegating", past: "Delegated", created: nil, object: .text),
        "todowrite": Look(tool: "TodoWrite", live: "Planning", past: "Updated the plan", created: nil, object: .none),
        "diagram": Look(tool: "Diagram", live: "Drawing", past: "Drew", created: nil, object: .text),
        "visualize": Look(tool: "Visualize", live: "Making a visual", past: "Made a visual", created: nil, object: .none),
        "visualguide": Look(tool: "VisualGuide", live: "Reading the visual guide", past: "Read the visual guide", created: nil, object: .none),
        "present": Look(tool: "Present", live: "Laying out", past: "Showed results", created: nil, object: .none),
        "ask": Look(tool: "Ask", live: "Asking", past: "Asked you", created: nil, object: .none),
        "skill": Look(tool: "Skill", live: "Loading skill", past: "Loaded skill", created: nil, object: .text),
        "mcptools": Look(tool: "McpTools", live: "Finding tools", past: "Found tools", created: nil, object: .text),
        "toolsearch": Look(tool: "McpTools", live: "Finding tools", past: "Found tools", created: nil, object: .text),
        "docs": Look(tool: "Docs", live: "Reading docs", past: "Read docs", created: nil, object: .text),
        "models": Look(tool: "Models", live: "Listing models", past: "Listed models", created: nil, object: .none),
        "settitle": Look(tool: "SetTitle", live: "Naming", past: "Named", created: nil, object: .text),
        "usefolder": Look(tool: "UseFolder", live: "Moving to", past: "Moved to", created: nil, object: .path),
        "sendmessage": Look(tool: "SendMessage", live: "Messaging", past: "Messaged", created: nil, object: .text),
        "recall": Look(tool: "Recall", live: "Recalling", past: "Recalled", created: nil, object: .text),
    ]

    /// The verbs for an engine tool name, any casing; an unknown tool is "Called" + its name.
    static func look(_ name: String) -> Look {
        table[name.lowercased()] ?? Look(tool: name, live: unknownLive, past: unknownPast, created: nil, object: .tool)
    }
}

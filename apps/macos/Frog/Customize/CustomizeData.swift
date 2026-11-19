import AppKit
import Foundation

/// What Customize shows, from what the engine and the files on disk can answer today: skills
/// (`frog --skills --json`), connections (`frog --mcp --json`), rules files (`frog --setup
/// --json`, then the files themselves), and memory notes (the engine's own note files).
///
/// Weight and use figures (tokens a turn, uses in the last 30 days) are the engine's to give
/// (the customize-engine API). Until it does they stay nil, and every view leaves them out
/// rather than draw a number nobody measured.

// MARK: - Skills

struct CustomizeSkill: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    /// The `SKILL.md` file, or `frog-builtin:<name>` for one Frog ships.
    let path: String
    /// Found under the project rather than the home folder.
    let project: Bool

    /// Engine figures, nil until the engine reports them.
    var tokensPerTurn: Int? = nil
    /// The whole file's weight, paid only on a turn that uses it.
    var fullTokens: Int? = nil
    /// Uses per day, oldest first, for the last 30 days.
    var uses: [Int]? = nil

    enum CodingKeys: String, CodingKey { case name, description, path, project }

    var id: String { name }
    var builtIn: Bool { path.hasPrefix("frog-builtin:") }
    var file: URL? { builtIn ? nil : URL(fileURLWithPath: path) }
}

// MARK: - Rules

/// One instruction file a session reads (AGENTS.md, FROG.md, CLAUDE.md).
struct RuleFile: Identifiable, Hashable {
    enum Scope: Hashable { case project, everywhere }
    let url: URL
    let scope: Scope
    /// The file's text, or empty for one not made yet (adding a line makes it).
    var text: String
    var exists: Bool
    var id: URL { url }
}

/// A line of a rules file, as a sheet shows it.
struct RuleLine: Identifiable, Hashable {
    enum Kind: Hashable { case heading, item, plain, code }
    /// The line's index in the file (0-based), the address every edit uses.
    let index: Int
    /// What comes before the words and survives an edit: indent and a list marker ("- ", "1. ").
    let prefix: String
    let text: String
    let kind: Kind
    var id: Int { index }
    var editable: Bool { kind == .item || kind == .plain }
}

/// Reading and changing a rules file a line at a time. Every byte outside the line touched
/// stays exactly as it was: headings, blank lines, code fences, line endings.
enum RuleText {
    /// The lines a sheet shows: blank lines and frontmatter left out, code kept but not editable.
    static func lines(_ text: String) -> [RuleLine] {
        let raw = split(text)
        var out: [RuleLine] = []
        var inFence = false
        var inFront = raw.first.map { trimmed($0) == "---" } ?? false
        for (i, line) in raw.enumerated() {
            let t = trimmed(line)
            if inFront {
                if i > 0, t == "---" { inFront = false }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                if !t.isEmpty { out.append(RuleLine(index: i, prefix: "", text: line.trimmingCharacters(in: .newlines), kind: .code)) }
                continue
            }
            if t.isEmpty || t.hasPrefix("<!--") { continue }
            if t.hasPrefix("#") {
                let words = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                out.append(RuleLine(index: i, prefix: "", text: words, kind: .heading))
                continue
            }
            let (prefix, words) = marker(line)
            out.append(RuleLine(index: i, prefix: prefix, text: words, kind: prefix.trimmingCharacters(in: .whitespaces).isEmpty ? .plain : .item))
        }
        return out
    }

    /// The file with line `index`'s words replaced, its indent and marker kept.
    static func replacing(_ text: String, at index: Int, with words: String) -> String {
        var raw = split(text)
        guard raw.indices.contains(index) else { return text }
        let (prefix, _) = marker(raw[index])
        let cr = raw[index].hasSuffix("\r") ? "\r" : ""
        raw[index] = prefix + oneLine(words) + cr
        return raw.joined(separator: "\n")
    }

    /// The file without line `index`.
    static func removing(_ text: String, at index: Int) -> String {
        var raw = split(text)
        guard raw.indices.contains(index) else { return text }
        raw.remove(at: index)
        return raw.joined(separator: "\n")
    }

    /// The file with one more line at the end, a list item if the line before it is one.
    static func appending(_ text: String, _ words: String) -> String {
        let words = oneLine(words)
        guard !words.isEmpty else { return text }
        let last = lines(text).last { $0.kind != .code }
        let prefix = last?.kind == .item ? last!.prefix : (last == nil ? "- " : "")
        let line = prefix + words
        if text.isEmpty { return line + "\n" }
        return text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A line's indent and list marker, then its words.
    static func marker(_ line: String) -> (String, String) {
        let body = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let pattern = #"^(\s*(?:[-*+]|\d+[.)])\s+|\s*)"#
        guard let r = body.range(of: pattern, options: .regularExpression) else { return ("", body) }
        return (String(body[r]), String(body[r.upperBound...]))
    }
}

// MARK: - Memory

/// One note Frog kept when you said "remember this" (the engine's memory files).
struct MemoryNote: Identifiable, Hashable {
    enum Scope: Hashable { case project, everywhere }
    let id: String
    let created: Date?
    let scope: Scope
    let body: String
    let url: URL
    var firstLine: String { body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "" }
}

enum MemoryFiles {
    /// `~/.local/share/frog/memory`, as the engine keeps it.
    static func root(home: URL) -> URL { home.appending(path: ".local/share/frog/memory") }

    /// The engine's folder for a project's notes: its main checkout's path as one name
    /// (`/Users/me/app` → `-Users-me-app`), shared by the project's worktrees.
    static func projectDir(root: URL, folder: URL) -> URL {
        root.appending(path: "projects").appending(path: key(projectRoot(folder).path))
    }

    static func key(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") ? $0 : "-" })
    }

    /// The checkout holding `folder`, or for a worktree, the main checkout it hangs off.
    static func projectRoot(_ folder: URL) -> URL {
        var dir = folder.standardizedFileURL
        while true {
            let dotgit = dir.appending(path: ".git")
            if FileManager.default.fileExists(atPath: dotgit.path) {
                if let s = try? String(contentsOf: dotgit, encoding: .utf8), s.hasPrefix("gitdir:") {
                    let gitdir = s.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let r = gitdir.range(of: "/.git/worktrees/") { return URL(fileURLWithPath: String(gitdir[..<r.lowerBound])) }
                }
                return dir
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return folder }
            dir = up
        }
    }

    /// Every note visible from `folder` (or everywhere only, for a chat), newest first.
    static func load(home: URL, folder: URL?) -> [MemoryNote] {
        let root = root(home: home)
        var dirs: [(URL, MemoryNote.Scope)] = [(root.appending(path: "global"), .everywhere)]
        if let folder { dirs.insert((projectDir(root: root, folder: folder), .project), at: 0) }
        var out: [MemoryNote] = []
        for (dir, scope) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "md" {
                if let n = read(url, scope: scope) { out.append(n) }
            }
        }
        return out.sorted { ($0.created ?? .distantPast, $1.id) > ($1.created ?? .distantPast, $0.id) }
    }

    static func read(_ url: URL, scope: MemoryNote.Scope) -> MemoryNote? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var meta: [String: String] = [:]
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for l in lines[1..<end] {
                if let c = l.firstIndex(of: ":") {
                    meta[l[..<c].trimmingCharacters(in: .whitespaces)] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let created = meta["created"].flatMap { ISO8601DateFormatter().date(from: $0) }
        return MemoryNote(id: url.deletingPathExtension().lastPathComponent, created: created, scope: scope, body: body, url: url)
    }

    /// Forget: the note's file goes to the Trash (`/forget` deletes it; from a page, a slip
    /// should be one you can take back).
    static func forget(_ note: MemoryNote) throws {
        try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
    }
}

// MARK: - Adding a connection

/// A server someone pasted on Add: a command Frog would run, or a link to a remote server.
/// Nothing runs until it's added; its tools are unknown until then.
struct ServerDraft: Hashable {
    var name: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?

    var remote: Bool { url != nil }
    /// The whole thing as pasted, tidied, for the From row.
    var shown: String {
        if let url { return url }
        let pre = env.keys.sorted().map { "\($0)=\(env[$0]!)" }
        return (pre + [command ?? ""] + args).joined(separator: " ")
    }

    /// A pasted link or command, or nil for words to search.
    static func parse(_ input: String) -> ServerDraft? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host() {
            return ServerDraft(name: name(fromHost: host, path: u.path), url: s)
        }
        var words = shellWords(s)
        var env: [String: String] = [:]
        while let w = words.first, let eq = w.firstIndex(of: "="), w[..<eq].allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }), eq != w.startIndex {
            env[String(w[..<eq])] = String(w[w.index(after: eq)...])
            words.removeFirst()
        }
        guard let cmd = words.first else { return nil }
        // One plain word with no path is a search, not a command.
        let known = ["npx", "uvx", "docker", "node", "python", "python3", "bunx", "deno", "pipx", "go"]
        guard words.count > 1 || cmd.contains("/") || known.contains(cmd) else { return nil }
        let args = Array(words.dropFirst())
        return ServerDraft(name: name(fromCommand: cmd, args: args), command: cmd, args: args, env: env)
    }

    /// Words as a shell splits them, with single and double quotes.
    static func shellWords(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var started = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started || !cur.isEmpty { out.append(cur); cur = ""; started = false }
            } else {
                cur.append(ch)
            }
        }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// A short name: the package after a runner (`npx -y @acme/mcp-server-postgres` → postgres).
    static func name(fromCommand cmd: String, args: [String]) -> String {
        let runners = ["npx", "uvx", "bunx", "pipx", "deno", "node", "python", "python3", "docker"]
        let pick = runners.contains(cmd) ? (args.first { !$0.hasPrefix("-") && $0 != "run" } ?? cmd) : cmd
        return tidy(pick)
    }

    static func name(fromHost host: String, path: String) -> String {
        let parts = host.split(separator: ".").filter { !["mcp", "api", "www", "com", "io", "dev", "app", "net", "org"].contains($0) }
        return tidy(String(parts.first ?? Substring(host)))
    }

    private static func tidy(_ s: String) -> String {
        var n = s.split(separator: "/").last.map(String.init) ?? s
        if let at = n.firstIndex(of: "@"), at != n.startIndex { n = String(n[..<at]) }
        for strip in ["mcp-server-", "server-", "-mcp-server", "-mcp", "mcp-"] { n = n.replacingOccurrences(of: strip, with: "") }
        n = n.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        return n.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "server" : n.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Writing it

    /// A `[mcp_servers.<name>]` table appended to config.toml: every byte already there stays.
    func tomlTable() -> String {
        var s = "\n[mcp_servers.\(Self.tomlKey(name))]\n"
        if let url {
            s += "url = \(Self.toml(url))\n"
        } else if let command {
            s += "command = \(Self.toml(command))\n"
            if !args.isEmpty { s += "args = [\(args.map(Self.toml).joined(separator: ", "))]\n" }
            if !env.isEmpty { s += "env = { \(env.keys.sorted().map { "\(Self.tomlKey($0)) = \(Self.toml(env[$0]!))" }.joined(separator: ", ")) }\n" }
        }
        return s
    }

    func appendToConfig(_ config: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        guard !Self.configHasServer(old, name) else { throw AddError.taken(name) }
        let joined = old.isEmpty || old.hasSuffix("\n") ? old + tomlTable() : old + "\n" + tomlTable()
        try joined.write(to: config, atomically: true, encoding: .utf8)
    }

    /// Into the project's `.mcp.json`, beside the servers already there.
    func addToProject(_ folder: URL) throws {
        let file = folder.appending(path: ".mcp.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AddError.unreadable }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard servers[name] == nil else { throw AddError.taken(name) }
        var entry: [String: Any] = [:]
        if let url {
            entry = ["type": "http", "url": url]
        } else if let command {
            entry["command"] = command
            if !args.isEmpty { entry["args"] = args }
            if !env.isEmpty { entry["env"] = env }
        }
        servers[name] = entry
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    enum AddError: LocalizedError, Equatable {
        case taken(String), unreadable
        var errorDescription: String? {
            switch self {
            case .taken(let n): "There's already a server called \(n). Pick another name."
            case .unreadable: "The project's .mcp.json isn't JSON Frog can read, so it was left alone."
            }
        }
    }

    static func configHasServer(_ toml: String, _ name: String) -> Bool {
        toml.components(separatedBy: "\n").contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "[mcp_servers.\(name)]" || t == "[mcp_servers.\"\(name)\"]"
        }
    }

    static func toml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tomlKey(_ s: String) -> String {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ? s : toml(s)
    }
}

// MARK: - The store

/// One window's Customize data, for the folder its focused pane is in (a chat sees only what's
/// everywhere). Loaded when the mode opens; reloaded after a change.
@MainActor @Observable
final class CustomizeStore {
    /// Off in tests: nothing starts `frog` or reads this Mac's files while a page renders.
    static var loads = true

    var home = FileManager.default.homeDirectoryForCurrentUser
    /// The project, or nil in a chat.
    private(set) var folder: URL?
    private(set) var skills: [CustomizeSkill]?
    private(set) var servers: [MCPStatus]?
    /// Servers that came with the project's .mcp.json.
    private(set) var projectServers: Set<String> = []
    private(set) var rules: [RuleFile]?
    private(set) var notes: [MemoryNote]?
    private(set) var signingIn: Set<String> = []
    /// The review page: add the server everywhere rather than to the project, and what went
    /// wrong adding it.
    var reviewEverywhere = false
    var reviewProblem: String?

    var projectName: String? { folder?.lastPathComponent }
    var configURL: URL { home.appending(path: ".config/frog/config.toml") }
    private var cwd: URL { folder ?? home }

    /// The window's folder, from the focused pane: a change starts over.
    func focus(_ folder: URL?) {
        guard folder?.standardizedFileURL != self.folder?.standardizedFileURL || skills == nil else { return }
        self.folder = folder
        guard Self.loads else { return }
        Task { await loadAll() }
    }

    func loadAll() async {
        async let s: Void = loadSkills()
        async let m: Void = loadServers()
        async let r: Void = loadRules()
        _ = await (s, m, r)
        loadNotes()
    }

    func loadSkills() async {
        skills = (try? await Frog.json([CustomizeSkill].self, args: ["--skills", "--json"], cwd: cwd)) ?? []
    }

    func loadServers() async {
        servers = nil
        projectServers = folder.map(Self.mcpJSONNames) ?? []
        servers = (try? await Frog.json([MCPStatus].self, args: ["--mcp", "--json"], cwd: cwd)) ?? []
    }

    func loadRules() async {
        let found = (try? await Frog.json(SetupReport.self, args: ["--setup", "--json"], cwd: cwd))?.instructions ?? []
        rules = Self.ruleFiles(found: found.map { URL(fileURLWithPath: $0) }, folder: folder, home: home)
    }

    func loadNotes() {
        notes = MemoryFiles.load(home: home, folder: folder)
    }

    /// The only thing here that opens a browser: a one-shot `frog --mcp-signin`, then the list
    /// reloads either way, the server's own state being the truth.
    func signIn(_ name: String) {
        guard !signingIn.contains(name) else { return }
        signingIn.insert(name)
        Task {
            try? await Frog.run(args: ["--mcp-signin", name], cwd: cwd)
            await loadServers()
            signingIn.remove(name)
        }
    }

    /// Adds a reviewed server where the review page says, then reloads the list.
    func add(_ draft: ServerDraft) -> Bool {
        reviewProblem = nil
        do {
            if let folder, !reviewEverywhere { try draft.addToProject(folder) } else { try draft.appendToConfig(configURL) }
        } catch {
            reviewProblem = error.localizedDescription
            return false
        }
        if Self.loads { Task { await loadServers() } }
        return true
    }

    func forget(_ note: MemoryNote) {
        try? MemoryFiles.forget(note)
        notes?.removeAll { $0.id == note.id && $0.scope == note.scope }
    }

    /// Writes a rules file's new text and keeps the page in step.
    func write(_ file: RuleFile, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file.url, atomically: true, encoding: .utf8)
        if let i = rules?.firstIndex(where: { $0.url == file.url }) {
            rules?[i].text = text
            rules?[i].exists = true
        }
    }

    /// The files a sheet each: the ones the engine reads, plus a place to start one where there
    /// is none (the project's AGENTS.md, and ~/.config/frog/FROG.md for everywhere).
    static func ruleFiles(found: [URL], folder: URL?, home: URL) -> [RuleFile] {
        let config = home.appending(path: ".config/frog")
        let everywhereRoots = [config.path, home.appending(path: ".claude").path]
        func scope(_ u: URL) -> RuleFile.Scope {
            everywhereRoots.contains { u.path.hasPrefix($0 + "/") } ? .everywhere : .project
        }
        var files = found.map { u in
            RuleFile(url: u, scope: scope(u), text: (try? String(contentsOf: u, encoding: .utf8)) ?? "", exists: true)
        }
        if let folder, !files.contains(where: { $0.scope == .project }) {
            files.insert(RuleFile(url: folder.appending(path: "AGENTS.md"), scope: .project, text: "", exists: false), at: 0)
        }
        if !files.contains(where: { $0.scope == .everywhere }) {
            files.append(RuleFile(url: config.appending(path: "FROG.md"), scope: .everywhere, text: "", exists: false))
        }
        // The project's first, as a session reads them nearest last but people look for theirs first.
        return files.filter { $0.scope == .project } + files.filter { $0.scope == .everywhere }
    }

    static func mcpJSONNames(_ folder: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: folder.appending(path: ".mcp.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return [] }
        return Set(servers.keys)
    }

    #if DEBUG
    /// Tests and snapshots: fixed data, nothing loaded.
    func stage(folder: URL?, skills: [CustomizeSkill], servers: [MCPStatus], projectServers: Set<String> = [],
               rules: [RuleFile], notes: [MemoryNote]) {
        self.folder = folder
        self.skills = skills
        self.servers = servers
        self.projectServers = projectServers
        self.rules = rules
        self.notes = notes
    }
    #endif
}

/// Opening a file the way the Mac would on a double-click (its default app for the type, never
/// a named editor), and showing one in Finder.
enum CustomizeFiles {
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

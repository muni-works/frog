import Foundation

/// What frog reads about a project when a conversation opens there, cheaply and without a
/// model (docs/onboarding.md, step 4): what it's written in, how big it is, and a few places
/// to start from its state.
struct ProjectGlance: Equatable, Sendable {
    /// Languages by share of lines, largest first ("Rust", "Swift").
    var languages: [String] = []
    var lines = 0
    /// Files with uncommitted changes.
    var changed = 0
    /// The latest commit's subject.
    var lastCommit: String?
    /// A TODO or FIXME in a recently changed file: path and the line's text.
    var todo: (path: String, text: String)?

    static func == (a: Self, b: Self) -> Bool {
        a.languages == b.languages && a.lines == b.lines && a.changed == b.changed
            && a.lastCommit == b.lastCommit && a.todo?.path == b.todo?.path && a.todo?.text == b.todo?.text
    }

    /// Something you could click to start, and what it sends.
    struct Start: Equatable, Identifiable {
        var title: String
        var prompt: String
        var id: String { title }
    }

    /// "Rust and Swift · 41k lines".
    var summary: String? {
        var parts: [String] = []
        switch languages.count {
        case 0: break
        case 1: parts.append(languages[0])
        default: parts.append(languages.prefix(2).joined(separator: " and "))
        }
        if lines >= 1000 { parts.append("\(lines / 1000)k lines") } else if lines > 0 { parts.append("\(lines) lines") }
        if changed > 0 { parts.append(changed == 1 ? "1 uncommitted change" : "\(changed) uncommitted changes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Up to three starting points, most specific first.
    var starts: [Start] {
        var out: [Start] = []
        if changed > 0 {
            out.append(Start(title: "Review my changes",
                             prompt: "Review my uncommitted changes (git diff) and point out anything that looks wrong or unfinished."))
        }
        if let todo {
            let name = (todo.path as NSString).lastPathComponent
            out.append(Start(title: "The TODO in \(name)",
                             prompt: "Look at this TODO in \(todo.path) and take care of it if it's straightforward: \(todo.text)"))
        }
        if changed == 0, let lastCommit {
            out.append(Start(title: "Pick up from the last commit",
                             prompt: "The last commit was “\(lastCommit)”. Look at what it changed and suggest what to do next."))
        }
        out.append(Start(title: "How it fits together",
                         prompt: "Explain how this project fits together: its main parts, how they talk to each other, and where to start reading."))
        return Array(out.prefix(3))
    }

    static let languageNames: [String: String] = [
        "rs": "Rust", "swift": "Swift", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript",
        "py": "Python", "go": "Go", "rb": "Ruby", "java": "Java", "kt": "Kotlin", "c": "C", "h": "C", "cc": "C++",
        "cpp": "C++", "hpp": "C++", "m": "Objective-C", "cs": "C#", "php": "PHP", "ex": "Elixir", "exs": "Elixir",
        "zig": "Zig", "lua": "Lua", "dart": "Dart", "scala": "Scala", "hs": "Haskell", "ml": "OCaml", "clj": "Clojure",
        "vue": "Vue", "svelte": "Svelte",
    ]

    /// Nil outside a git repository.
    static func load(_ folder: URL) async -> ProjectGlance? {
        await Task.detached(priority: .utility) { read(folder) }.value
    }

    nonisolated static func read(_ folder: URL) -> ProjectGlance? {
        guard let files = Git.run(folder, ["ls-files"]) else { return nil }
        var g = ProjectGlance()
        // Lines by language, over source files only, bounded so a huge repo stays quick.
        var byLanguage: [String: Int] = [:]
        for path in files.split(separator: "\n").prefix(8000) {
            let ext = (path as NSString).pathExtension.lowercased()
            guard let lang = languageNames[ext],
                  let data = FileManager.default.contents(atPath: folder.appending(path: String(path)).path),
                  data.count < 2_000_000 else { continue }
            byLanguage[lang, default: 0] += data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        }
        g.lines = byLanguage.values.reduce(0, +)
        // Languages worth naming: at least a tenth of the code.
        g.languages = byLanguage.filter { $0.value * 10 >= g.lines }.sorted { $0.value > $1.value }.map(\.key)
        g.changed = Git.run(folder, ["status", "--porcelain"])?.split(separator: "\n").count ?? 0
        g.lastCommit = Git.run(folder, ["log", "-1", "--format=%s"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if g.lastCommit?.isEmpty == true { g.lastCommit = nil }
        g.todo = recentTodo(folder)
        return g
    }

    /// The first TODO or FIXME in a source file changed in the last ten commits.
    private static func recentTodo(_ folder: URL) -> (path: String, text: String)? {
        guard let changed = Git.run(folder, ["log", "-10", "--name-only", "--format="]) else { return nil }
        var seen = Set<String>()
        let paths = changed.split(separator: "\n").map(String.init)
            .filter { languageNames[($0 as NSString).pathExtension.lowercased()] != nil && seen.insert($0).inserted }
            .prefix(40)
        guard !paths.isEmpty,
              let hits = Git.run(folder, ["grep", "-n", "-I", "-E", "\\b(TODO|FIXME)\\b", "--"] + paths) else { return nil }
        for hit in hits.split(separator: "\n") {
            // "path:12:    // TODO: handle the empty case"
            let parts = hit.split(separator: ":", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let text = parts[2].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/#*-; "))
            guard text.count > 8, text.count < 160 else { continue }
            return (String(parts[0]), text)
        }
        return nil
    }
}

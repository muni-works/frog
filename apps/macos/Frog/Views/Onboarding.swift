import SwiftUI

/// What an empty conversation offers under its question (docs/onboarding.md): recent projects
/// in a new chat, one line saying what frog found on this Mac, and the model suggestion. Each
/// is a line or less, and goes away once it's done or dismissed.
struct EmptyPageExtras: View {
    let conversation: Conversation
    @State private var report: SetupReport?
    @AppStorage("setupLineClosed") private var setupClosed = false

    private var isChat: Bool { Frog.isChat(conversation.folder) }

    /// One line at a time: what frog found comes first, then the model suggestion.
    private var showsSetup: Bool { !setupClosed && !(report?.toAdd.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 10) {
            if isChat {
                RecentProjectChips()
            }
            if showsSetup {
                SetupLine(conversation: conversation, report: report)
            } else {
                ModelSuggestion(conversation: conversation)
            }
        }
        // Here, not on the line: a view with nothing to show yet never appears, so its task
        // wouldn't run.
        .task(id: conversation.folder) { report = await SetupReport.load(conversation.folder) }
    }
}

// MARK: - Recent projects

/// Up to three projects you've been working in, one click from a conversation there.
struct RecentProjectChips: View {
    @Environment(\.switchFolder) private var switchFolder
    @State private var library = Library.shared
    @State private var found: [URL] = []

    static let limit = 3

    /// Where frog looks for git repositories when there's little history yet.
    static let roots = ["Developer", "Projects", "code", "src", "dev"]

    /// Folders of recent conversations first, then frog's recent folders, then repositories
    /// by latest activity.
    private var projects: [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        let history = library.sessions.compactMap { s in s.isChat ? nil : s.folder }
        for url in history + Recents.all + found {
            let key = url.standardizedFileURL.path
            guard !Frog.isChat(url), !key.contains("/.claude/worktrees/"), seen.insert(key).inserted else { continue }
            out.append(url)
            if out.count == Self.limit { break }
        }
        return out
    }

    var body: some View {
        let list = projects
        HStack(spacing: 8) {
            ForEach(list, id: \.path) { url in
                Button { switchFolder?(url) } label: {
                    Label {
                        Text(url.lastPathComponent).lineLimit(1)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(FolderTint.color(url))
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
        }
        .task {
            // Only needed while there's little history; cheap either way (one level deep).
            found = await Task.detached(priority: .utility) { Self.repositories() }.value
        }
    }

    /// Git repositories one level under the usual folders, most recently active first.
    nonisolated static func repositories() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var repos: [(URL, Date)] = []
        for root in roots {
            let dir = home.appending(path: root)
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for child in children {
                let git = child.appending(path: ".git")
                // A commit or checkout touches the index; a worktree's .git is a file.
                let marker = [git.appending(path: "index"), git]
                    .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                    .first
                if let date = marker { repos.append((child, date)) }
            }
        }
        return repos.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

// MARK: - What frog found

/// What `frog --setup` found for a folder.
struct SetupReport: Decodable, Equatable {
    var instructions: [String]
    var skills: Int
    var rules: Int
    var envKeys: [String]
    var claudeMcp: [String]
    var claudeMcpOn: Bool

    /// Claude Code's MCP servers frog could add.
    var toAdd: [String] { claudeMcpOn ? [] : claudeMcp }

    /// "CLAUDE.md, 56 skills, your Anthropic key": what's already in use.
    var inUse: [String] {
        var out: [String] = []
        let names = Set(instructions.map { URL(fileURLWithPath: $0).lastPathComponent })
        out += ["CLAUDE.md", "AGENTS.md"].filter(names.contains)
        if skills > 0 { out.append("\(skills) skill\(skills == 1 ? "" : "s")") }
        if rules > 0 { out.append("\(rules) rule\(rules == 1 ? "" : "s")") }
        out += envKeys.map { "your \($0) key" }
        return out
    }

    /// One report per folder per launch: the setup rarely changes while the app runs.
    @MainActor static var cache: [String: SetupReport] = [:]

    @MainActor
    static func load(_ folder: URL) async -> SetupReport? {
        let key = folder.standardizedFileURL.path
        if let r = cache[key] { return r }
        let r = try? await Frog.json(SetupReport.self, args: ["--setup", "--json"], cwd: folder)
        if let r { cache[key] = r }
        return r
    }
}

/// "Using your Claude Code setup: CLAUDE.md, 56 skills. Also found 4 MCP servers. Use them",
/// shown while there's something frog could add. Using them restarts the (still empty)
/// conversation so the servers connect.
struct SetupLine: View {
    let conversation: Conversation
    let report: SetupReport?
    @Environment(\.switchFolder) private var switchFolder
    @AppStorage("setupLineClosed") private var closed = false
    @State private var added = false

    var body: some View {
        Group {
            if !closed, let r = report, !r.toAdd.isEmpty || added {
                HStack(spacing: 4) {
                    if added {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Using \(r.claudeMcp.count) MCP server\(r.claudeMcp.count == 1 ? "" : "s") from Claude Code.")
                    } else {
                        if !r.inUse.isEmpty {
                            Text("Using your Claude Code setup: \(r.inUse.joined(separator: ", ")).")
                        }
                        Text("Found \(r.toAdd.count) MCP server\(r.toAdd.count == 1 ? "" : "s").")
                            .help(r.toAdd.joined(separator: ", "))
                        Button("Use Them") { use(r) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                    }
                    Button {
                        closed = true
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .help("Don't show this again")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .transition(.opacity)
            }
        }
    }

    private func use(_ r: SetupReport) {
        Task {
            _ = try? await Frog.run(args: ["--use-claude-mcp", "on"], cwd: conversation.folder)
            SetupReport.cache = [:]
            withAnimation { added = true }
            // Nothing's been said yet: start over so the servers connect.
            if conversation.turns.isEmpty {
                let folder = conversation.folder
                switchFolder?(Frog.isChat(folder) ? nil : folder)
            }
        }
    }
}

import SwiftUI

/// What an empty conversation offers under its question (docs/onboarding.md): recent projects
/// in a new chat, one line saying what frog found on this Mac, and the model suggestion. Each
/// is a line or less, and goes away once it's done or dismissed.
struct EmptyPageExtras: View {
    let conversation: Conversation
    @State private var report: SetupReport?
    @State private var glance: ProjectGlance?
    @AppStorage("setupLineClosed") private var setupClosed = false

    private var isChat: Bool { Frog.isChat(conversation.folder) }

    /// One line at a time: what frog found comes first, then the model suggestion.
    private var showsSetup: Bool { !setupClosed && !(report?.toAdd.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 10) {
            if isChat {
                RecentProjectChips()
            } else if let glance {
                ProjectGreeting(conversation: conversation, glance: glance)
            }
            if showsSetup {
                SetupLine(conversation: conversation, report: report)
            } else {
                ModelSuggestion(conversation: conversation)
            }
        }
        // Here, not on the line: a view with nothing to show yet never appears, so its task
        // wouldn't run.
        .task(id: conversation.folder) {
            if !isChat { glance = await ProjectGlance.load(conversation.folder) }
            report = await SetupReport.load(conversation.folder)
        }
    }
}

// MARK: - The project greeting

/// What frog read about a project, in one line, and up to three places to start: "Rust and
/// Swift · 41k lines · 3 uncommitted changes", then "Review my changes", "The TODO in
/// engine.rs", "How it fits together". A click sends it.
struct ProjectGreeting: View {
    let conversation: Conversation
    let glance: ProjectGlance

    var body: some View {
        VStack(spacing: 10) {
            if let summary = glance.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach(glance.starts) { start in
                    Button { conversation.submit(start.prompt) } label: {
                        Text(start.title)
                            .lineLimit(1)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help(start.prompt)
                }
            }
        }
        .transition(.opacity)
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

// MARK: - A bigger model, when it's needed

/// One line above the composer when a small model (Apple Intelligence's 8k window) is out of
/// its depth: the conversation outgrew it, it went in circles, or it's working in a project.
/// It offers the next step up on your devices (use it if it's ready, get it if not) and in the
/// cloud, and picking switches the conversation without losing it (docs/onboarding.md).
struct BiggerModelLine: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var closed = false
    @State private var asking: ModelIdentity?
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    /// Windows under this are small (see the engine's compact mode).
    static let smallWindow: UInt64 = 16_384

    private var current: ModelIdentity? {
        conversation.status.map { workspace.identity($0.model) }
    }

    private var reason: String? {
        guard !closed, !conversation.busy, let s = conversation.status, let name = current?.name else { return nil }
        return Self.reason(model: name, window: s.contextWindow, turns: conversation.turns, inProject: !workspace.isChat)
    }

    /// Why it's showing, in words; nil when it shouldn't: the model is small and the
    /// conversation outgrew it, it went in circles, or it's doing work in a project.
    static func reason(model name: String, window: UInt64, turns: [TurnState], inProject: Bool) -> String? {
        guard window < smallWindow else { return nil }
        switch turns.last?.end {
        case .error(let e) where e.description.localizedCaseInsensitiveContains("context"):
            return "This conversation outgrew \(name)."
        case .looping, .stepLimit, .maxTokens:
            return "\(name) is struggling with this."
        default:
            let worked = turns.contains { $0.finished && $0.number != nil }
            return inProject && worked ? "\(name) is small for work in a project." : nil
        }
    }

    /// The next step up on your devices: one that's ready (a server's, a download), else the
    /// download that suits this Mac.
    private var onDevices: ModelIdentity {
        let ready = workspace.models.map(ModelIdentity.init)
            .filter { $0.state.isReady && !$0.place.isCloud && $0.place != .apple && $0.spec != current?.spec }
        if let m = ready.first { return m }
        return ModelIdentity(SuggestedModel.forThisMac)
    }

    private var inCloud: ModelIdentity? {
        workspace.models.map { workspace.allowing(ModelIdentity($0)) }.first { $0.place.isCloud && $0.state.isReady }
    }

    var body: some View {
        if let reason {
            HStack(spacing: 4) {
                Text(reason)
                let local = onDevices
                Button(local.state.isReady ? "Use \(local.name)" : "Get \(local.name)") { pick(local) }
                    .buttonStyle(.link)
                    .foregroundStyle(local.place.color)
                if !local.state.isReady, let gb = local.downloadGB {
                    Text("(\(String(format: "%.1f GB", gb)))")
                }
                Text("or")
                if let cloud = inCloud {
                    Button("use \(cloud.name)") { pick(cloud) }
                        .buttonStyle(.link)
                        .foregroundStyle(cloud.place.color)
                } else {
                    Button("add a cloud key") {
                        settingsTab = "models"
                        openSettings()
                    }
                    .buttonStyle(.link)
                }
                Button { closed = true } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
                .help("Keep using \(current?.name ?? "this model")")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .transition(.opacity)
            .sheet(item: Binding(get: { asking.map(AskingCloudModel.init) }, set: { if $0 == nil { asking = nil } })) { a in
                CloudPermissionSheet(workspace: workspace, model: a.model) { allowed in
                    asking = nil
                    if allowed { workspace.use(a.model.spec) }
                }
            }
        }
    }

    /// Like picking it in the picker: a download switches over when it's done, a cloud model
    /// asks the project first.
    private func pick(_ m: ModelIdentity) {
        if m.place.isCloud && workspace.mustAskForCloud { asking = m; return }
        if m.state.isReady { workspace.use(m.spec) } else { workspace.useWhenReady(m) }
    }
}

private struct AskingCloudModel: Identifiable {
    let model: ModelIdentity
    var id: String { model.spec }
}

// MARK: - Ping you when it's done?

/// Notifications are asked about once, the first time a task runs longer than half a minute:
/// "This is taking a while. Ping you when it's done? Yes · No thanks". Yes asks the system;
/// either answer is remembered, and the setting stays in Settings > General.
struct PingLine: View {
    let conversation: Conversation
    @AppStorage("pingAsked") private var asked = false
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @State private var due = false

    static let after: TimeInterval = 30

    private var started: Date? {
        guard conversation.busy, let turn = conversation.turns.last, !turn.finished else { return nil }
        return turn.startedAt
    }

    var body: some View {
        Group {
            if due && !asked && conversation.busy {
                HStack(spacing: 4) {
                    Text("This is taking a while. Ping you when it's done?")
                    Button("Yes") {
                        asked = true
                        notifyWhenDone = true
                        Task { await Notifier.shared.ask() }
                    }
                    .buttonStyle(.link)
                    Text("·").foregroundStyle(.tertiary)
                    Button("No thanks") {
                        asked = true
                        notifyWhenDone = false
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .task(id: started) {
            due = false
            guard !asked, let started else { return }
            let wait = started.addingTimeInterval(Self.after).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, notifyWhenDone else { return }
            // Already answered in System Settings (or earlier): nothing to ask.
            guard await Notifier.shared.notAskedYet() else { asked = true; return }
            withAnimation(.snappy) { due = true }
        }
    }
}

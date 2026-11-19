import SwiftUI

/// What the where menu lists, gathered by the live composer (or a test's fixture).
struct WhereLists: Equatable {
    /// Recent folders, full paths, most recent first.
    var recents: [String] = []
    /// Repos the Frog GitHub App reaches ("owner/name").
    var cloudRepos: [String] = []
    /// Each repo's last push on GitHub (ISO 8601), for the order (`RepoRank`).
    var pushed: [String: String] = [:]
    /// Repos used in Frog Cloud, most recent first.
    var usedRepos: [String] = []
    var signedIn = false
    /// The current place's branches, for the Branch level.
    var branches: [String] = []
    /// The Mac's groups (This Mac, Just chat, New worktree). The web has none of them.
    var mac = true
}

/// The where chip: place icon, name in the normal colour, branch in muted, a chevron.
struct WhereChipLabel: View {
    let place: ComposerModel.Where
    var narrow = false

    var body: some View {
        ComposerIcon(place.icon)
        Text(Self.middle(place.name, narrow ? 12 : 32)).foregroundStyle(Tokens.text).fixedSize()
        if !narrow, let branch = place.branch {
            Text(Self.middle(branch, 24)).fixedSize()
        }
        ComposerIcon("chevron.down")
    }

    /// "ecto/sl…wich": the ends kept, the middle dropped.
    static func middle(_ s: String, _ limit: Int) -> String {
        guard s.count > limit, limit > 3 else { return s }
        let tail = (limit - 1) * 2 / 5, head = limit - 1 - tail
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}

/// One menu for where the work runs, opening upward (board 2): a filter, This Mac, Frog Cloud,
/// Just chat, then Branch and New worktree for the current choice.
struct WhereMenu: View {
    let state: ComposerModel.State
    let lists: WhereLists
    let send: (ComposerModel.Intent) -> Void
    var chooseFolder: () -> Void = {}
    var signIn: () -> Void = {}
    var close: () -> Void = {}
    @State private var filter = ""
    @State private var branches = false
    @State private var lit = 0

    private struct Row: Identifiable {
        var id: String
        var icon: String?
        var title: String
        var detail: String?
        var checked = false
        var dim = false
        var chevron = false
        var toggle: Bool?
        var run: () -> Void
    }

    private enum Entry: Identifiable {
        case label(String)
        case rule(Int)
        case row(Row)
        case note(String)
        case more(String)
        var id: String {
            switch self {
            case .label(let t): "label-\(t)"
            case .rule(let n): "rule-\(n)"
            case .row(let r): r.id
            case .note(let t): "note-\(t)"
            case .more: "more"
            }
        }
    }

    private var q: String { filter.trimmingCharacters(in: .whitespaces).lowercased() }
    private func matches(_ s: String) -> Bool { q.isEmpty || s.lowercased().contains(q) }

    /// A GitHub URL pasted into the filter picks that repo.
    static func githubRepo(_ s: String) -> String? {
        guard let r = s.range(of: #"github\.com[/:]([\w.-]+)/([\w.-]+?)(\.git)?(/|$)"#, options: .regularExpression) else { return nil }
        let parts = s[r].replacingOccurrences(of: "github.com:", with: "github.com/").split(separator: "/")
        guard parts.count >= 3 else { return nil }
        let name = parts[2].hasSuffix(".git") ? String(parts[2].dropLast(4)) : String(parts[2])
        return "\(parts[1])/\(name)"
    }

    private static func home(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }

    private func pick(_ intent: ComposerModel.Intent) {
        send(intent)
        close()
    }

    private var placeEntries: [Entry] {
        var out: [Entry] = []
        var folder: String?
        var repo: String?
        switch state.where {
        case .folder(let f, _, _, _, _): folder = f
        case .cloud(let r, _): repo = r
        default: break
        }
        if lists.mac {
            var recents = lists.recents
            if let folder, !recents.contains(folder) { recents.insert(folder, at: 0) }
            let shown = recents.filter { matches(($0 as NSString).lastPathComponent) }.prefix(8)
            if !shown.isEmpty || q.isEmpty { out.append(.label("This Mac")) }
            for f in shown {
                out.append(.row(Row(id: "folder-\(f)", icon: "folder", title: (f as NSString).lastPathComponent,
                                    detail: Self.home((f as NSString).deletingLastPathComponent), checked: f == folder) {
                    pick(.chooseFolder(folder: f, branch: "", git: true, dirty: false))
                }))
            }
            if q.isEmpty {
                out.append(.row(Row(id: "choose", icon: "folder.badge.plus", title: "Choose a folder…", dim: true) {
                    close()
                    chooseFolder()
                }))
            }
        }
        if lists.signedIn {
            // The best few (RepoRank); the rest are a search away, with one line saying how many.
            let ranked = RepoRank.rank(current: repo == "No repo" ? nil : repo, used: lists.usedRepos,
                                       repos: lists.cloudRepos.map { ($0, lists.pushed[$0]) })
            let (shown, more) = RepoRank.pick(ranked, query: filter)
            var repos = shown
            if let pasted = Self.githubRepo(filter), !repos.contains(where: { $0.lowercased() == pasted.lowercased() }) { repos.insert(pasted, at: 0) }
            let noRepo = matches("No repo")
            if !repos.isEmpty || noRepo { out.append(.label("Frog Cloud")) }
            for r in repos {
                out.append(.row(Row(id: "cloud-\(r)", icon: "cloud", title: r, checked: r.lowercased() == repo?.lowercased()) { pick(.chooseCloud(repo: r, branch: "main")) }))
            }
            if let line = RepoRank.moreLine(more, searching: !q.isEmpty) { out.append(.more(line)) }
            if noRepo {
                out.append(.row(Row(id: "no-repo", icon: "cloud", title: "No repo", checked: repo == "No repo") { pick(.chooseCloud(repo: "No repo", branch: "")) }))
            }
        } else if q.isEmpty {
            out.append(.label("Frog Cloud"))
            out.append(.row(Row(id: "sign-in", icon: "cloud", title: "Sign in to use Frog Cloud", dim: true) {
                close()
                signIn()
            }))
        }
        if lists.mac, matches("Just chat") {
            out.append(.rule(1))
            var chat = false
            if case .chat = state.where { chat = true }
            out.append(.row(Row(id: "chat", icon: "bubble.left", title: "Just chat", checked: chat) { pick(.justChat) }))
        }
        guard q.isEmpty else { return out }
        switch state.where {
        case .folder(_, let branch, let worktree, true, let dirty):
            out.append(.rule(2))
            if dirty {
                out.append(.row(Row(id: "branch", title: "Branch", detail: branch, dim: true, chevron: false) {}))
                out.append(.note("Commit your changes to switch branches"))
            } else {
                out.append(.row(Row(id: "branch", title: "Branch", detail: branch, chevron: true) { openBranches() }))
            }
            if lists.mac {
                out.append(.row(Row(id: "worktree", title: "New worktree", toggle: worktree) { send(.toggleWorktree) }))
            }
        case .cloud(let r, let branch) where r != "No repo":
            out.append(.rule(2))
            out.append(.row(Row(id: "branch", title: "Branch", detail: branch, chevron: true) { openBranches() }))
        default:
            break
        }
        return out
    }

    private var branchEntries: [Entry] {
        let current = state.where.branch
        var list = lists.branches
        if let current, !list.contains(current) { list.insert(current, at: 0) }
        return list.filter(matches).map { b in
            .row(Row(id: "b-\(b)", title: b, checked: b == current) { pick(.pickBranch(b)) })
        }
    }

    private func openBranches() {
        filter = ""
        lit = 0
        branches = true
    }

    private var entries: [Entry] { branches ? branchEntries : placeEntries }

    private var rows: [Row] {
        entries.compactMap { if case .row(let r) = $0, !(r.dim && !r.chevron && r.id == "branch") { return r }; return nil }
    }

    var body: some View {
        let rows = rows
        let litID = rows.isEmpty ? nil : rows[min(max(lit, 0), rows.count - 1)].id
        ComposerMenuPanel(width: 340) {
            ComposerMenuFilter(
                placeholder: branches ? "Search branches" : lists.mac ? "Search folders and repos" : "Search repos, or paste a GitHub URL",
                text: $filter,
                move: { lit = min(max(lit + $0, 0), max(rows.count - 1, 0)) },
                pick: { if let id = litID { rows.first { $0.id == id }?.run() } },
                close: close
            )
            ForEach(entries) { e in
                switch e {
                case .label(let t): ComposerMenuLabel(t)
                case .rule: ComposerMenuRule()
                case .note(let t):
                    Text(t).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                        .padding(.horizontal, 8).padding(.bottom, 6)
                case .more(let t):
                    Text(t).font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                case .row(let r):
                    if let on = r.toggle {
                        ComposerMenuButton(lit: r.id == litID, action: r.run) {
                            HStack {
                                Text(r.title).foregroundStyle(Tokens.text)
                                Spacer(minLength: 6)
                                ComposerSwitch(on: on)
                            }
                        }
                    } else {
                        ComposerMenuRow(icon: r.icon, title: r.title, detail: r.detail, checked: r.checked, dim: r.dim,
                                        chevron: r.chevron, lit: r.id == litID, action: r.run)
                            .disabled(r.dim && r.id == "branch")
                    }
                }
            }
        }
        .onChange(of: filter) { lit = 0 }
    }
}

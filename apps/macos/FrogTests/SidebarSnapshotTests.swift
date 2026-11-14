import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The attention tree rendered from a staged org (the design's mockup data, roughly), into
/// `$TMPDIR/frog-snapshots/sidebar-<scope>-<look>.png`, for review against
/// docs/design/sidebar-shots/7-recommended-*.png.
@MainActor
final class SidebarSnapshotTests: XCTestCase {
    private var outDir: URL {
        FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    private let keys = ["sidebarGroup", "sidebarScope", "sidebarSort", "calmSidebar"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        Library.shared.unstage()
        GitIndex.shared.unstage()
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    private static let now = Int64(Date().timeIntervalSince1970 * 1000)

    private static func s(_ id: String, _ title: String, ago minutes: Double, repo: String = "frog",
                          end: SessionInfo.End? = .complete) -> SessionInfo {
        let t = now - Int64(minutes * 60_000)
        return SessionInfo(id: id, modified: t, created: t - 600_000, model: "anthropic/claude-opus-5.5",
                           firstInput: nil, title: title, end: end, forkedFrom: nil,
                           cwd: "/Users/cam/Developer/\(repo)/.frog/worktrees/\(id)")
    }

    /// The org on Oct 25 (titles from the design's mockups), states staged for one moment.
    private func stage() {
        let chief = SessionInfo(id: "chief", modified: Self.now, created: Self.now - 86_400_000, model: "anthropic/claude-opus-5.5",
                                firstInput: nil, title: "chief", end: .complete, forkedFrom: nil, cwd: "/Users/cam/Developer")
        let sessions: [SessionInfo] = [
            chief,
            Self.s("fm", "frog manager", ago: 0.2),
            Self.s("grace", "graceful restart implementation", ago: 0.3),
            Self.s("drill", "restart drill tests", ago: 0.1),
            Self.s("gdesign", "graceful restart design", ago: 180),
            Self.s("deleg", "delegation pipeline v4", ago: 300),
            Self.s("orgrel", "org reliability fixes", ago: 310),
            Self.s("opus", "opus text-mode fix", ago: 320),
            Self.s("perf", "transcript perf batch", ago: 330),
            Self.s("ux", "accounts ux spec v3", ago: 340),
            Self.s("revert", "mode silently reverts", ago: 360, end: .failed),
            Self.s("old1", "sidebar status v2", ago: 2000),
            Self.s("old2", "compact sidebar", ago: 2100),
            Self.s("okc", "okc manager", ago: 12, repo: "okc"),
            Self.s("decode", "okc decode layer", ago: 1, repo: "okc"),
            Self.s("bf16", "okc bf16 proj", ago: 4, repo: "okc"),
            Self.s("prefill", "okc prefill layer", ago: 1, repo: "okc"),
            Self.s("attn", "okc attn decode", ago: 120, repo: "okc"),
            Self.s("serve", "okc serving patch", ago: 180, repo: "okc"),
            Self.s("cloud", "frog cloud manager", ago: 0.5, repo: "zest"),
            Self.s("keys", "frog api keys", ago: 0.5, repo: "zest"),
            Self.s("batch", "gateway batching", ago: 1, repo: "zest"),
            Self.s("tang", "tang manager", ago: 600, repo: "tang"),
            Self.s("t1", "kv ttl", ago: 1500, repo: "tang"),
            Self.s("t2", "kernel registry", ago: 1600, repo: "tang"),
            Self.s("rose", "rose head mvp setup", ago: 4300, repo: "rose"),
            Self.s("cd1", "renew daemon.so", ago: 200, repo: "home"),
            Self.s("cd2", "licensing audit", ago: 1300, repo: "home"),
            Self.s("blaze", "blaze distill", ago: 0.4, repo: "blaze"),
            Self.s("node", "Make the frog cloud node boot from a fresh image", ago: 4400, repo: "zest"),
            Self.s("mine-old", "kino stream eval", ago: 3000, repo: "kino"),
        ]
        let parents = [
            "fm": "chief", "okc": "chief", "cloud": "chief", "tang": "chief", "rose": "chief", "cd1": "chief", "cd2": "chief",
            "grace": "fm", "drill": "grace", "gdesign": "grace", "deleg": "fm", "orgrel": "fm", "opus": "fm", "perf": "fm",
            "ux": "fm", "revert": "fm", "old1": "fm", "old2": "fm",
            "decode": "okc", "bf16": "okc", "prefill": "okc", "attn": "okc", "serve": "okc",
            "keys": "cloud", "batch": "cloud", "t1": "tang", "t2": "tang",
        ]
        let live: [String: Library.Live] = [
            "chief": .running, "fm": .running, "grace": .running, "drill": .running, "decode": .running,
            "bf16": .waiting, "prefill": .running, "cloud": .running, "keys": .running, "batch": .waiting, "blaze": .running, "node": .unread,
        ]
        Library.shared.stage(sessions: sessions, live: live, parents: parents, chief: "chief",
                             archived: [], asks: ["bf16": "pod past its 2h cap · $3.50/hr · extend?",
                                                  "batch": "Bash git push origin gateway-batching"])
    }

    /// Git badges (docs/design/sidebar-git): sidebar-git-{today,live}-{light,dark}.png, and the
    /// two hover cards, git-card-{group,session}-{light,dark}.png.
    func testRenderGitBadges() throws {
        stage()
        func b(_ id: String, ahead: Int = 0, dirty: Int = 0, landed: GitBadge.Landed = .no,
               trouble: GitBadge.Trouble? = nil, repo: String = "frog") -> GitBadge {
            GitBadge(tree: "/Users/cam/Developer/\(repo)/.frog/worktrees/\(id)", branch: "frog/\(id)", base: "origin/main",
                     ahead: ahead, behind: 12, dirty: dirty, landed: landed, trouble: trouble)
        }
        let badges: [String: GitBadge] = [
            "grace": b("grace", ahead: 4, dirty: 6), "drill": b("drill", ahead: 1), "gdesign": b("gdesign", landed: .ancestor),
            "deleg": b("deleg", ahead: 10), "orgrel": b("orgrel", landed: .ancestor), "opus": b("opus", landed: .pr(97)),
            "perf": b("perf", landed: .ancestor), "ux": b("ux", ahead: 17), "revert": b("revert", ahead: 2, trouble: .rebasing),
            "old1": b("old1", landed: .ancestor), "old2": b("old2", landed: .ancestor),
            "decode": b("decode", ahead: 6, dirty: 19, repo: "okc"), "bf16": b("bf16", ahead: 2, repo: "okc"),
            "prefill": b("prefill", ahead: 3, dirty: 2, repo: "okc"), "attn": b("attn", ahead: 1, dirty: 1, repo: "okc"),
            "serve": b("serve", landed: .ancestor, repo: "okc"),
            "keys": b("keys", ahead: 12, repo: "zest"), "batch": b("batch", ahead: 8, repo: "zest"),
            "t1": b("t1", landed: .ancestor, repo: "tang"), "t2": b("t2", ahead: 5, repo: "tang"),
            "cd1": b("cd1", ahead: 4, repo: "home"),
        ]
        let now = Date()
        let card = GitIndex.Card(
            landed: [
                .init(id: "77b5f8c", title: "main conflict fix", slug: "ecto/frog", sha: "77b5f8c", url: nil, statKey: "m:1", date: now),
                .init(id: "b36d033", title: "subagent visibility", slug: "ecto/frog", sha: "b36d033", url: nil, statKey: "m:2", date: now),
                .init(id: "ef41cd7", title: "worktree ux", slug: "ecto/frog", sha: "ef41cd7", url: nil, statKey: "m:3", date: now),
                .init(id: "92fabc4", title: "transcript: instant session switch + virtualization", session: "transcript perf batch",
                      slug: "ecto/frog", pr: 104, url: nil, statKey: "m:4", date: now),
                .init(id: "c7aad00", title: "engine: never persist native→text downgrades", session: "opus text-mode fix",
                      slug: "ecto/frog", pr: 97, url: nil, statKey: "m:5", date: now),
            ],
            pending: [
                .init(id: "ux", title: "accounts ux spec v3", branch: "frog/accounts-ux-spec", ahead: 17, statKey: "d:1"),
                .init(id: "deleg", title: "delegation pipeline v4", branch: "frog/delegation-pipeline", ahead: 10, statKey: "d:2"),
                .init(id: "revert", title: "mode silently reverts", branch: "frog/revert", ahead: 2, trouble: .rebasing),
            ],
            moreLanded: 6, morePending: 1)
        let stats: [String: GitParse.DiffStat] = [
            "m:1": .init(files: 2, added: 6, removed: 11), "m:2": .init(files: 21, added: 1751, removed: 378),
            "m:3": .init(files: 3, added: 653, removed: 1), "m:4": .init(files: 10, added: 1165, removed: 38),
            "m:5": .init(files: 3, added: 751, removed: 78), "d:1": .init(files: 23, added: 1241, removed: 0),
            "d:2": .init(files: 14, added: 2611, removed: 51),
        ]
        GitIndex.shared.stage(badges, card: card, stats: stats)
        for scope in [AttentionTree.Scope.today, .live] {
            UserDefaults.standard.set("org", forKey: "sidebarGroup")
            UserDefaults.standard.set(scope.rawValue, forKey: "sidebarScope")
            UserDefaults.standard.set("activity", forKey: "sidebarSort")
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/grace"), resume: "grace")
                try render(SessionList(workspace: ws, maxHeight: 900).background(.background),
                           size: CGSize(width: 300, height: 900), to: "sidebar-git-\(scope.rawValue)-\(name)", appearance: look)
            }
        }
        let group = GitCardController.Request(id: "g", title: "frog manager", sessions: [], single: false,
                                              counts: "11 landed · 33 ahead", open: { _ in }, refresh: {})
        let one = GitCardController.Request(id: "s", title: "subagent visibility v2", sessions: [], single: true,
                                            counts: "2 ahead", open: { _ in }, refresh: {})
        let ownCard = GitIndex.Card(
            landed: [.init(id: "b36d033", title: "subagent visibility", slug: "ecto/frog", sha: "b36d033", url: nil, statKey: "m:2", date: now)],
            pending: [.init(id: "sv", title: "subagent visibility v2", branch: "frog/subagent-visibility", ahead: 2,
                            statKey: "d:3", commitsKey: "c:1", dirty: 0)])
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            GitIndex.shared.stage(badges, card: card, stats: stats)
            try render(GitCard(request: group).padding(20), size: CGSize(width: 460, height: 420), to: "git-card-group-\(name)", appearance: look)
            GitIndex.shared.stage(badges, card: ownCard, stats: stats.merging(["d:3": .init(files: 1, added: 13, removed: 0)]) { a, _ in a },
                                  commits: ["c:1": [.init(sha: "fa29b9a", subject: "notes: rebase onto the fixed main; local fix superseded"),
                                                    .init(sha: "a4237cb", subject: "notes: main's broken merge (c816903) and the resolution")]])
            try render(GitCard(request: one, pinned: true).padding(20), size: CGSize(width: 460, height: 240), to: "git-card-session-\(name)", appearance: look)
        }
    }

    func testRenderAttentionTree() throws {
        stage()
        for scope in AttentionTree.Scope.allCases {
            UserDefaults.standard.set("org", forKey: "sidebarGroup")
            UserDefaults.standard.set(scope.rawValue, forKey: "sidebarScope")
            UserDefaults.standard.set("activity", forKey: "sidebarSort")
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/grace"), resume: "grace")
                try render(SessionList(workspace: ws, maxHeight: 900).background(.background),
                           size: CGSize(width: 288, height: 900), to: "sidebar-\(scope.rawValue)-\(name)", appearance: look)
            }
        }
        // Search filters the tree in place: "okc" keeps its manager, and the archive below.
        Library.shared.stage(sessions: Library.shared.sessions + [Self.s("okc-old", "okc dyno plan", ago: 9000, repo: "okc")],
                             live: Library.shared.live, parents: Library.shared.parents, chief: "chief",
                             archived: ["okc-old"])
        let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/grace"), resume: "grace")
        try render(SessionList(workspace: ws, maxHeight: 900, query: "okc").background(.background),
                   size: CGSize(width: 288, height: 600), to: "sidebar-search-light", appearance: .aqua)
    }

    /// The started-by tree with child sessions in every state (retired background agents'
    /// replacement): sidebar-children-{light,dark}.png. A parent running, one child running,
    /// one needing you (its ask as the second line), one done with its PR.
    func testRenderChildSessionTree() throws {
        let parent = Self.s("lead", "retire background agents", ago: 0.1)
        let sessions: [SessionInfo] = [
            parent,
            Self.s("engine", "engine-owned child sessions", ago: 0.2),
            Self.s("tree", "mac tree child states", ago: 0.3),
            Self.s("webnest", "web session nesting", ago: 6),
            Self.s("other", "transcript perf batch", ago: 40),
        ]
        func restage() {
            Library.shared.stage(
                sessions: sessions,
                live: ["lead": .running, "engine": .running, "tree": .waiting],
                parents: ["engine": "lead", "tree": "lead", "webnest": "lead"],
                asks: ["tree": AskPhrase.line(name: "Bash", arg: "cargo test -p frog-engine kids")])
        }
        restage()
        GitIndex.shared.stage([
            "engine": GitBadge(tree: "/Users/cam/Developer/frog/.frog/worktrees/engine", branch: "frog/engine-owned-child-sessions",
                               base: "origin/main", ahead: 3, behind: 0, dirty: 2, landed: .no, trouble: nil),
            "webnest": GitBadge(tree: "/Users/cam/Developer/frog/.frog/worktrees/webnest", branch: "frog/web-session-nesting",
                                base: "origin/main", ahead: 0, behind: 0, dirty: 0, landed: .pr(281), trouble: nil),
        ], card: nil, stats: [:])
        // The default view: by date (the calm list), where children now nest too.
        UserDefaults.standard.set(true, forKey: "calmSidebar")
        UserDefaults.standard.set("date", forKey: "sidebarGroup")
        UserDefaults.standard.set("activity", forKey: "sidebarSort")
        let compact = UserDefaults.standard.object(forKey: "compactSidebar")
        defer { UserDefaults.standard.set(compact, forKey: "compactSidebar") }
        for (dense, suffix) in [(false, ""), (true, "-compact")] {
            UserDefaults.standard.set(dense, forKey: "compactSidebar")
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                restage()  // a sidebar's onAppear refresh can replace a staged listing
                let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/other"), resume: "other")
                try render(SessionList(workspace: ws, maxHeight: 420).background(.background),
                           size: CGSize(width: 300, height: 420), to: "sidebar-children\(suffix)-\(name)", appearance: look)
            }
        }
    }

    /// The sidebar's rows and the composer's pill, one above the other, from one list of bound
    /// PRs: sidebar-prs-{light,dark}.png. What the bug was: "3 PRs, all merged" in the composer
    /// and "#312" in the row, with the other two invisible.
    func testRenderPRsAgreeing() throws {
        let sessions: [SessionInfo] = [
            Self.s("three", "three PRs bound", ago: 1).withPrs([
                .init(repo: "muni-works/frog", number: 300, title: "tray", state: "merged"),
                .init(repo: "muni-works/frog", number: 301, title: "hover", state: "merged"),
                .init(repo: "muni-works/frog", number: 312, title: "chip hover", state: "merged"),
            ]),
            Self.s("one", "one PR bound", ago: 2).withPrs([
                .init(repo: "muni-works/frog", number: 312, title: "chip hover", state: "merged"),
            ]),
            Self.s("worst", "two merged, one failing", ago: 3).withPrs([
                .init(repo: "muni-works/frog", number: 300, title: "tray", state: "merged"),
                .init(repo: "muni-works/frog", number: 301, title: "hover", state: "failing"),
            ]),
        ]

        /// The composer's own view of a session: the same bindings, through the one summary.
        func tray(_ s: SessionInfo) -> ComposerModel.State {
            var state = ComposerModel.State(
                model: .init(id: "local/qwen3-4b", name: "Qwen3 4B · On this Mac", place: .local, node: nil),
                where: .session(.init(repo: "muni-works/frog", branch: "frog/pr-chip-hover",
                                      worktree: true, worktreePath: s.cwd,
                                      diff: .init(add: 12, del: 3, files: 2), dirty: false, ahead: 0,
                                      prs: GitIndex.shared.prs(s.prs))))
            state.draft = .init(text: "", attachments: [], caret: 0)
            return state
        }
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            Library.shared.stage(sessions: sessions)
            try render(VStack(alignment: .leading, spacing: 12) {
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 5) {
                        // The row, as the sidebar draws it…
                        HStack(spacing: 0) {
                            Text(s.displayTitle).font(.frog(size: 13)).lineLimit(1)
                            Spacer(minLength: 6)
                            if let status = RowStatus.of(.done, prs: Library.shared.rowLine(s).prs) {
                                RowStatusView(status: status).fixedSize()
                            }
                        }
                        .padding(.horizontal, 10)
                        // …and the same thread's composer, from the same bound list.
                        TrayPreview(state: tray(s))
                    }
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background), size: CGSize(width: 620, height: 360), to: "sidebar-prs-\(name)", appearance: look)
            Library.shared.unstage()
        }
    }

    /// The started-by tree's rails, at every depth a session can sit at: a six-deep chain
    /// (depths 0–5) beside a sibling leaf, in every grouping and both looks, with a nested row
    /// selected — tree-rails-*.png. The chain is the whole point: a row at depth 5 must look
    /// deeper than one at depth 4, and its guide must survive selection.
    ///
    /// Both groupings matter. The date list always drew a guide (`TreeGuide`); the **org** tree
    /// (`TreeRow`) drew none, so "the rail is faint" was really "the org tree has no rail".
    /// Rendered as `tree-rails-<group>-<mode>-<pick>-<look>`.
    func testRenderTreeRails() throws {
        // root › depth1 › depth2 › depth3 › depth4 › depth5, plus a sibling at depth 1.
        let chain = ["d1", "d2", "d3", "d4", "d5"]
        var sessions: [SessionInfo] = [Self.s("root", "tree design pass", ago: 0.1)]
        for (i, id) in chain.enumerated() {
            sessions.append(Self.s(id, "level \(i + 1) worker", ago: 0.2 + Double(i) * 0.1))
        }
        sessions.append(Self.s("leaf", "sibling worker", ago: 1.5))
        var parents: [String: String] = ["leaf": "root"]
        parents["d1"] = "root"
        for (i, id) in chain.enumerated().dropFirst() { parents[id] = chain[i - 1] }
        let live: [String: Library.Live] = [
            "root": .running, "d1": .running, "d2": .waiting, "d3": .running, "leaf": .running,
        ]
        func restage() {
            Library.shared.stage(sessions: sessions, live: live, parents: parents, chief: nil, archived: [])
        }
        UserDefaults.standard.set(true, forKey: "calmSidebar")
        UserDefaults.standard.set("activity", forKey: "sidebarSort")
        let compactSaved = UserDefaults.standard.object(forKey: "compactSidebar")
        defer { UserDefaults.standard.set(compactSaved, forKey: "compactSidebar") }

        // The row on screen: a nested one, so its selection fill has a rail to either side.
        let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/d3"), resume: "d3")
        // The org tree is the one the brief's screenshot came from; the date list is the one
        // that always had a guide. Both are renders now, to prove they agree.
        for group in ["org", "date"] {
            UserDefaults.standard.set(group, forKey: "sidebarGroup")
            for (dense, mode) in [(false, "two-line"), (true, "compact")] {
                UserDefaults.standard.set(dense, forKey: "compactSidebar")
                for (selected, pick) in [(nil, "plain"), ("d3", "selected")] {
                    for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                        restage()  // the sidebar's onAppear refresh can replace a staged listing
                        ws.opening = selected
                        try render(SessionList(workspace: ws, maxHeight: 460).background(Tokens.sidebar),
                                   size: CGSize(width: 300, height: 460),
                                   to: "tree-rails-\(group)-\(mode)-\(pick)-\(name)",
                                   appearance: look)
                    }
                }
            }
        }
        ws.opening = nil
    }

    /// The ask card: two answers and a ⋯, into ask-card-{light,dark}.png.
    func testRenderAskCard() throws {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "s")
        let line = #"{"seq":1,"session":"s","created":1790113417019,"event":"permission_request","id":"p1","item":"t5","name":"Bash","arg":"cargo test -p frog-engine kids","always":"always allow `cargo test`"}"#
        c.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
        let request = try XCTUnwrap(c.permission)
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try render(PermissionCard(request: request, conversation: c).padding(16).background(.background),
                       size: CGSize(width: 560, height: 200), to: "ask-card-\(name)", appearance: look)
        }
    }
}

private extension SessionInfo {
    /// The same session with bound PRs, as the listing carries them.
    func withPrs(_ prs: [PrBinding]) -> SessionInfo {
        var s = self
        s.prs = prs
        return s
    }
}

import CoreServices
import Foundation
import Observation

/// Git for the sidebar's badges (docs/design/sidebar-git/README.md §3). One index for every
/// session's tree: drawing a row only reads it, and git only runs here, off the main thread:
/// once per repo when its refs change (an FSEvents watch on the common dir, so a commit, merge,
/// push or fetch anywhere lands), and once per tree when a session there settles. The network
/// is used only on an explicit Refresh.
@MainActor
@Observable
final class GitIndex {
    static let shared = GitIndex()

    /// Tree top → its badge. The only state rows observe.
    private(set) var badges: [String: GitBadge] = [:]
    /// The hover card's lazily read numbers, by key (`m:` a merge, `d:` a branch vs base).
    private(set) var stats: [String: GitParse.DiffStat] = [:]
    /// A branch's own commits (`c:<base>..<tip>`), for the session card.
    private(set) var commits: [String: [Commit]] = [:]

    struct Commit: Equatable, Sendable, Identifiable {
        var sha: String
        var subject: String
        var id: String { sha }
    }

    /// A folder's git checkout, from the filesystem alone (`.git` dir or file, as
    /// `worktree::linked` reads it).
    struct TreeRef: Hashable, Sendable {
        var top: String
        var gitDir: String
        var common: String
        /// The repo's main checkout (or anything that isn't a linked worktree).
        var main: Bool
    }

    private struct TreeState {
        var ref: TreeRef
        var dirty: Int?
        var conflicts = 0
        var detachedAhead: Int?
        var statusAt: Date?
        /// A status that timed out backs off until then.
        var backoff: Date?
        /// The branch tip the last status saw (a new commit re-reads it).
        var tip: String?
    }

    private struct Repo {
        var common: String
        /// Any checkout of it, to run git in.
        var dir: String
        var base: String?
        var baseSha: String?
        var refs: [String: GitParse.Ref] = [:]
        /// Branches on the base's remote (for compare links).
        var remote: Set<String> = []
        var slug: String?
        var merges: [GitParse.Merge] = []
        var mergesFor: String?
        /// "tip base" → every commit is patch-equivalent in base.
        var cherry: [String: Bool] = [:]
        /// tip → a pull request gh said merged (asked on Refresh).
        var pr: [String: Int] = [:]
        var refreshing = false
        var again = false
        /// `%(ahead-behind)` isn't in this git (< 2.41): count per tree instead.
        var oldGit = false
    }

    @ObservationIgnored private var folders: [String: TreeRef?] = [:]
    @ObservationIgnored private var trees: [String: TreeState] = [:]
    @ObservationIgnored private var repos: [String: Repo] = [:]
    @ObservationIgnored private var watchers: [String: RefWatcher] = [:]
    @ObservationIgnored private var sessionTree: [String: String] = [:]
    @ObservationIgnored private var seen: [String: (modified: Int64, end: SessionInfo.End?)] = [:]
    @ObservationIgnored private var statusQueue: [String] = []
    @ObservationIgnored private var statusRunning = false
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var debounce: [String: Task<Void, Never>] = [:]
    /// Sessions running or waiting (their trees don't get status reads).
    @ObservationIgnored private var busy: Set<String> = []

    private init() {}

    // MARK: Rows

    /// The badge for `session`'s tree; nil for no git (or not read yet).
    func badge(_ session: SessionInfo) -> GitBadge? {
        #if DEBUG
        if let staged { return staged.badges[session.id].flatMap { badges[$0.tree] } }
        #endif
        guard let top = sessionTree[session.id] else { return nil }
        return badges[top]
    }

    #if DEBUG
    /// Snapshot tests: badges by session id, and the card every row shows.
    @ObservationIgnored private var staged: (badges: [String: GitBadge], card: Card?)?

    func stage(_ bySession: [String: GitBadge], card: Card? = nil, stats: [String: GitParse.DiffStat] = [:],
               commits: [String: [Commit]] = [:]) {
        staged = (bySession, card)
        badges = Dictionary(bySession.values.map { ($0.tree, $0) }, uniquingKeysWith: { a, _ in a })
        self.stats = stats
        self.commits = commits
    }

    func unstage() {
        staged = nil
        badges = [:]
        stats = [:]
        commits = [:]
    }

    var stagedCard: Card? { staged?.card }
    #endif

    /// A row is on screen: read its tree's status if it hasn't been (at most once a minute).
    func wantStatus(_ session: SessionInfo) {
        guard let top = sessionTree[session.id], let t = trees[top], !t.ref.main else { return }
        if let at = t.statusAt, Date().timeIntervalSince(at) < 60 { return }
        enqueueStatus(top)
    }

    // MARK: Listing and live state

    /// The listing changed: map new sessions to trees, start watching new repos, and re-read the
    /// status of trees whose sessions moved on while settled.
    func listingChanged(_ sessions: [SessionInfo]) {
        var newRepos: Set<String> = []
        for s in sessions {
            guard let folder = s.cwd, !(s.folder.map(FrogPaths.isChat) ?? false) else { continue }
            guard let ref = tree(folder) else { continue }
            sessionTree[s.id] = ref.top
            if trees[ref.top] == nil { trees[ref.top] = TreeState(ref: ref) }
            if repos[ref.common] == nil {
                repos[ref.common] = Repo(common: ref.common, dir: ref.top)
                newRepos.insert(ref.common)
            }
            let was = seen[s.id]
            seen[s.id] = (s.modified, s.end)
            // (A session this app doesn't have open moves on with every listing: 10 s apart at most.)
            if let was, was.modified != s.modified, !busy.contains(s.id), !ref.main { enqueueStatus(ref.top, every: 10) }
        }
        for common in newRepos {
            watch(common)
            refreshRepo(common)
        }
    }

    /// Live states changed: a session that stopped running settles its tree, so read it.
    func liveChanged(from old: [String: SessionLive], to new: [String: SessionLive]) {
        busy = Set(new.filter { $0.value == .running || $0.value == .waiting }.map(\.key))
        for (id, state) in old where state == .running && new[id] != .running {
            if let top = sessionTree[id], trees[top]?.ref.main == false { enqueueStatus(top) }
        }
    }

    // MARK: Trees

    /// The checkout `folder` is in, walking up to the `.git` (cached per folder).
    func tree(_ folder: String) -> TreeRef? {
        if let hit = folders[folder] { return hit }
        let ref = Self.resolve(folder)
        folders[folder] = ref
        return ref
    }

    nonisolated static func resolve(_ folder: String) -> TreeRef? {
        let fm = FileManager.default
        var at = URL(fileURLWithPath: folder).standardizedFileURL
        while true {
            let dot = at.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dot.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let gd = dot.resolvingSymlinksInPath().path
                    return TreeRef(top: at.resolvingSymlinksInPath().path, gitDir: gd, common: gd, main: true)
                }
                guard let text = try? String(contentsOf: dot, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : at.appendingPathComponent(raw))
                    .standardizedFileURL.resolvingSymlinksInPath()
                let linked = gitDir.deletingLastPathComponent().lastPathComponent == "worktrees"
                var common = gitDir
                if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                    let c = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    common = (c.hasPrefix("/") ? URL(fileURLWithPath: c) : gitDir.appendingPathComponent(c))
                        .standardizedFileURL.resolvingSymlinksInPath()
                }
                return TreeRef(top: at.resolvingSymlinksInPath().path, gitDir: gitDir.path, common: common.path, main: !linked)
            }
            let up = at.deletingLastPathComponent()
            if up.path == at.path { return nil }
            at = up
        }
    }

    // MARK: Refresh

    /// Re-read `common`'s refs (and what depends on them), coalescing bursts.
    func refreshRepo(_ common: String) {
        guard var repo = repos[common] else { return }
        if repo.refreshing { repo.again = true; repos[common] = repo; return }
        repo.refreshing = true
        repos[common] = repo
        let snapshot = repo
        let tips = trees.values.filter { $0.ref.common == common }.compactMap { t -> String? in
            Self.headFile(t.ref).branch.flatMap { snapshot.refs[$0]?.sha }
        }
        Task {
            let next = await Task.detached(priority: .utility) { Self.batch(snapshot, knownTips: Set(tips)) }.value
            guard var repo = repos[common] else { return }
            let again = repo.again
            let oldRefs = repo.refs
            repo = next
            repo.refreshing = false
            repo.again = false
            repos[common] = repo
            // A settled tree whose tip moved (a commit by hand, a merge) is re-read.
            for (top, t) in trees where t.ref.common == common && !t.ref.main {
                guard let branch = Self.headFile(t.ref).branch, let tip = repo.refs[branch]?.sha else { continue }
                if oldRefs[branch]?.sha != tip, t.tip != nil, !treeBusy(top) { enqueueStatus(top) }
            }
            recompose(common)
            if again { refreshRepo(common) }
        }
    }

    /// Explicit refresh (the row menu, the hover card): fetch each repo's base once, re-read
    /// them, and (for one session's card) ask gh about its branch. The only place frog reaches
    /// the network for badges.
    func refreshFromRemote(_ sessions: [SessionInfo], askGitHub: Bool) {
        var tops: [String] = []
        for s in sessions { if let top = sessionTree[s.id], !tops.contains(top) { tops.append(top) } }
        var fetched: Set<String> = []
        for top in tops {
            guard let t = trees[top], let repo = repos[t.ref.common] else { continue }
            let fetch = fetched.insert(t.ref.common).inserted
            guard fetch || askGitHub else { enqueueStatus(top); continue }
            refresh(top, ref: t.ref, base: repo.base, fetch: fetch, askGitHub: askGitHub && tops.count == 1)
        }
    }

    private func refresh(_ top: String, ref: TreeRef, base: String?, fetch: Bool, askGitHub: Bool) {
        let dir = top, common = ref.common
        let branch = Self.headFile(ref).branch
        Task {
            let pr = await Task.detached(priority: .userInitiated) { () -> (tip: String, n: Int)? in
                if fetch, let base, let slash = base.firstIndex(of: "/") {
                    _ = Self.git(dir, ["fetch", "--quiet", String(base[..<slash]), String(base[base.index(after: slash)...])], timeout: 30)
                }
                guard askGitHub, let branch, let gh = Self.gh(),
                      let out = Self.run(gh, ["pr", "view", branch, "--json", "number,state,headRefOid"], in: dir, timeout: 15),
                      let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      json["state"] as? String == "MERGED", let n = json["number"] as? Int,
                      let tip = json["headRefOid"] as? String else { return nil }
                return (tip, n)
            }.value
            if let pr { repos[common]?.pr[pr.tip] = pr.n }
            enqueueStatus(top)
            refreshRepo(common)
        }
    }

    private func treeBusy(_ top: String) -> Bool {
        sessionTree.contains { $0.value == top && busy.contains($0.key) }
    }

    private func enqueueStatus(_ top: String, every: TimeInterval = 0) {
        if let t = trees[top], let b = t.backoff, b > Date() { return }
        if every > 0, let at = trees[top]?.statusAt, Date().timeIntervalSince(at) < every { return }
        guard !statusQueue.contains(top) else { return }
        statusQueue.append(top)
        guard !statusRunning else { return }
        statusRunning = true
        Task { await drainStatus() }
    }

    private func drainStatus() async {
        while !statusQueue.isEmpty {
            let top = statusQueue.removeFirst()
            guard let t = trees[top], let repo = repos[t.ref.common] else { continue }
            let ref = t.ref, base = repo.base
            let result = await Task.detached(priority: .utility) { Self.status(ref, base: base) }.value
            guard var t = trees[top] else { continue }
            if let result {
                t.dirty = result.dirty
                t.conflicts = result.conflicts
                t.detachedAhead = result.detachedAhead
                t.tip = result.tip
                t.statusAt = Date()
                t.backoff = nil
            } else {
                t.backoff = Date().addingTimeInterval(600)
            }
            trees[top] = t
            compose(top)
        }
        statusRunning = false
    }

    // MARK: Compose

    private func recompose(_ common: String) {
        for (top, t) in trees where t.ref.common == common { compose(top) }
    }

    private func compose(_ top: String) {
        guard let t = trees[top], let repo = repos[t.ref.common] else { return }
        let b = Self.compose(t.ref, repo: repo, dirty: t.dirty, conflicts: t.conflicts, detachedAhead: t.detachedAhead)
        if badges[top] != b { badges[top] = b }
    }

    nonisolated private static func compose(_ ref: TreeRef, repo: Repo, dirty: Int?, conflicts: Int,
                                            detachedAhead: Int?) -> GitBadge? {
        let head = headFile(ref)
        let baseBranch = repo.base.map { b in b.firstIndex(of: "/").map { String(b[b.index(after: $0)...]) } ?? b }
        // The main checkout on its base branch has nothing of its own to show.
        if ref.main, head.branch == nil || head.branch == baseBranch || head.branch == repo.base { return nil }
        var b = GitBadge(tree: ref.top, branch: head.branch, base: repo.base, mainCheckout: ref.main)
        b.dirty = dirty
        b.head = head.sha.map { String($0.prefix(7)) }
        var tip: String?
        if let branch = head.branch, let r = repo.refs[branch] {
            b.ahead = r.ahead
            b.behind = r.behind
            tip = r.sha
        } else if head.branch == nil {
            b.ahead = detachedAhead
            tip = head.sha
        }
        if repo.base == nil { b.ahead = nil }
        if let tip, repo.base != nil {
            if b.ahead == 0 {
                // In base. A fresh branch is too (it was made there): it landed only if a merge
                // brought it in, or it moved since it was made.
                let brought: Bool = repo.merges.contains { $0.brought.contains(tip) }
                // Named apart from the static `created(_:_:)`: a local that shares the name and is
                // used in its own initializer crashes older Swift type-checkers.
                var madeAt: String? = nil
                if let branch = head.branch { madeAt = Self.created(repo.common, branch) }
                let moved: Bool = madeAt != nil && madeAt != tip
                let pr: Int? = repo.pr[tip]
                if brought || moved || pr != nil {
                    b.landed = pr.map { GitBadge.Landed.pr($0) } ?? .ancestor
                }
            } else if let n = repo.pr[tip] {
                b.landed = .pr(n)
                b.ahead = 0
            } else if repo.cherry["\(tip) \(repo.baseSha ?? "")"] == true {
                b.landed = .patchEquivalent
                b.ahead = 0
            }
        }
        b.trouble = trouble(ref, conflicts: conflicts)
        return b
    }

    nonisolated private static func trouble(_ ref: TreeRef, conflicts: Int) -> GitBadge.Trouble? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: ref.gitDir)
        if fm.fileExists(atPath: dir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("rebase-apply").path) { return .rebasing }
        if fm.fileExists(atPath: dir.appendingPathComponent("MERGE_HEAD").path) { return .merging }
        if fm.fileExists(atPath: dir.appendingPathComponent("CHERRY_PICK_HEAD").path) { return .cherryPicking }
        return conflicts > 0 ? .conflicts(conflicts) : nil
    }

    nonisolated private static func headFile(_ ref: TreeRef) -> (branch: String?, sha: String?) {
        guard let text = try? String(contentsOfFile: ref.gitDir + "/HEAD", encoding: .utf8) else { return (nil, nil) }
        return GitParse.head(text)
    }

    nonisolated private static func created(_ common: String, _ branch: String) -> String? {
        guard let text = try? String(contentsOfFile: common + "/logs/refs/heads/" + branch, encoding: .utf8) else { return nil }
        return GitParse.created(text)
    }

    // MARK: Git (off the main actor)

    /// One repo's refs against its base: two `for-each-ref`s, the remote's branches, the merge
    /// index when the base moved, and `git cherry` for tips not proven or cached.
    nonisolated private static func batch(_ old: Repo, knownTips: Set<String>) -> Repo {
        var r = old
        let dir = r.dir
        if r.slug == nil, let url = git(dir, ["config", "--get", "remote.origin.url"]) {
            r.slug = GitParse.slug(remote: url)
        }
        r.base = base(dir)
        guard let base = r.base else { r.refs = [:]; return r }
        r.baseSha = git(dir, ["rev-parse", "--verify", "--quiet", base])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let out = git(dir, ["for-each-ref", "--format=%(objectname) %(refname) %(ahead-behind:\(base))", "refs/heads"]) {
            r.refs = GitParse.aheadBehind(out)
            r.oldGit = false
        } else {
            // Older git: ahead/behind per branch that a tree is on.
            r.oldGit = true
            var refs: [String: GitParse.Ref] = [:]
            let heads = git(dir, ["for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads"]) ?? ""
            for line in heads.split(separator: "\n") {
                let f = line.split(separator: " ")
                guard f.count == 2, knownTips.contains(String(f[0])) else { continue }
                if let c = git(dir, ["rev-list", "--left-right", "--count", "\(base)...\(f[0])"]) {
                    let n = c.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                    if n.count == 2 { refs[String(f[1])] = .init(sha: String(f[0]), ahead: n[1], behind: n[0]) }
                }
            }
            r.refs = refs
        }
        if let slash = base.firstIndex(of: "/") {
            let remote = String(base[..<slash])
            let out = git(dir, ["for-each-ref", "--format=%(refname:short)", "refs/remotes/\(remote)"]) ?? ""
            r.remote = Set(out.split(separator: "\n").map { s in
                s.hasPrefix(remote + "/") ? String(s.dropFirst(remote.count + 1)) : String(s)
            })
        }
        if let sha = r.baseSha, r.mergesFor != sha {
            if let out = git(dir, ["log", base, "--first-parent", "--merges", "-n", "200", "--format=\(GitParse.mergeFormat)"]) {
                r.merges = GitParse.merges(out)
                r.mergesFor = sha
            }
        }
        if let sha = r.baseSha {
            for ref in r.refs.values where ref.ahead > 0 && knownTips.contains(ref.sha) {
                let key = "\(ref.sha) \(sha)"
                guard r.cherry[key] == nil, let out = git(dir, ["cherry", base, ref.sha]) else { continue }
                r.cherry[key] = !out.split(separator: "\n").contains { $0.hasPrefix("+") }
            }
        }
        return r
    }

    /// The branch a repo's worktrees are compared against: the remote's default, else
    /// `origin/main|master`, else a local `main|master` (as `SessionBroker.worktreeBase`).
    nonisolated private static func base(_ dir: String) -> String? {
        if let head = git(dir, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty { return head }
        for c in ["origin/main", "origin/master", "main", "master"] where git(dir, ["rev-parse", "--verify", "--quiet", c]) != nil {
            return c
        }
        return nil
    }

    private struct Status: Sendable {
        var dirty: Int, conflicts: Int, detachedAhead: Int?, tip: String?
    }

    /// A tree's uncommitted changes (and, detached, its commits ahead). Nil when it took
    /// longer than 2 s (a huge tree backs off).
    nonisolated private static func status(_ ref: TreeRef, base: String?) -> Status? {
        guard let out = git(ref.top, ["status", "--porcelain=v2", "--branch"], timeout: 2) else { return nil }
        let s = GitParse.status(out)
        let tip = out.split(separator: "\n").first { $0.hasPrefix("# branch.oid ") }.map { String($0.dropFirst("# branch.oid ".count)) }
        var ahead: Int?
        if headFile(ref).branch == nil, let base,
           let n = git(ref.top, ["rev-list", "--count", "\(base)..HEAD"]) {
            ahead = Int(n.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Status(dirty: s.dirty, conflicts: s.conflicts, detachedAhead: ahead, tip: tip)
    }

    /// `git -C dir args`, its output or nil (failed, or killed at `timeout`). Never takes
    /// optional locks, so a status read can't collide with a session's own git.
    nonisolated static func git(_ dir: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        run("/usr/bin/git", ["-C", dir] + args, in: dir, timeout: timeout)
    }

    nonisolated private static func gh() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func run(_ exe: String, _ args: [String], in dir: String, timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Watching

    private func watch(_ common: String) {
        guard watchers[common] == nil else { return }
        watchers[common] = RefWatcher(path: common) { [weak self] paths in
            guard paths.contains(where: Self.matters) else { return }
            Task { @MainActor in self?.refsChanged(common) }
        }
    }

    /// Ref and HEAD moves, rebase/merge state; not objects, the index or lock files.
    nonisolated private static func matters(_ path: String) -> Bool {
        if path.hasSuffix(".lock") || path.contains("/objects/") || path.contains("/logs/") { return false }
        return path.contains("/refs/") || path.hasSuffix("/packed-refs") || path.hasSuffix("/HEAD")
            || path.contains("/rebase-merge") || path.contains("/rebase-apply")
    }

    private func refsChanged(_ common: String) {
        debounce[common]?.cancel()
        debounce[common] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refreshRepo(common)
        }
    }
}

// MARK: - The hover card's data

extension GitIndex {
    /// A merge (or squash) that brought a tree's work into its base.
    struct Landed: Identifiable, Equatable {
        var id: String
        var title: String
        /// The session's title, when the pull request's differs.
        var session: String? = nil
        var slug: String? = nil
        var pr: Int? = nil
        var sha: String? = nil
        var url: URL? = nil
        var statKey: String? = nil
        var date: Date
    }

    /// A tree with commits not in its base.
    struct Pending: Identifiable, Equatable {
        var id: String
        var title: String
        var branch: String? = nil
        var ahead: Int
        var statKey: String? = nil
        var commitsKey: String? = nil
        var url: URL? = nil
        var trouble: GitBadge.Trouble? = nil
        var dirty: Int? = nil
    }

    struct Card: Equatable {
        var landed: [Landed] = []
        var pending: [Pending] = []
        /// Landed rows beyond the ones listed.
        var moreLanded = 0
        var morePending = 0
    }

    /// The card for `sessions` (a group's subtree, or one session): landed newest first, then
    /// what hasn't landed, most ahead first. Built from the index alone; stats load lazily.
    func card(_ sessions: [SessionInfo], landedLimit: Int = 8, pendingLimit: Int = 5) -> Card {
        #if DEBUG
        if let c = stagedCard { return c }
        #endif
        var byTree: [String: SessionInfo] = [:]
        for s in sessions {
            guard let top = sessionTree[s.id], badges[top] != nil else { continue }
            if let had = byTree[top], had.modified >= s.modified { continue }
            byTree[top] = s
        }
        var landed: [Landed] = []
        var pending: [Pending] = []
        var seenMerges: Set<String> = []
        for (top, s) in byTree {
            guard let badge = badges[top], let t = trees[top], let repo = repos[t.ref.common] else { continue }
            let tip = badge.branch.flatMap { repo.refs[$0]?.sha }
            let merges = Self.merges(of: badge, tip: tip, in: repo)
            for m in merges where seenMerges.insert(m.sha).inserted {
                let title = m.title ?? s.displayTitle
                landed.append(Landed(
                    id: m.sha, title: title, session: m.title != nil && m.title != s.displayTitle ? s.displayTitle : nil,
                    slug: repo.slug, pr: m.pr, sha: String(m.sha.prefix(7)),
                    url: repo.slug.flatMap { slug in m.pr.flatMap { GitLinks.pr(slug, $0) } ?? GitLinks.commit(slug, m.sha) },
                    statKey: "m:\(m.sha)", date: m.date))
            }
            if badge.isLanded, merges.isEmpty {
                // Squashed or fast-forwarded: no merge commit to point at.
                let n: Int? = if case .pr(let n) = badge.landed { n } else { nil }
                landed.append(Landed(id: "tree:" + top, title: s.displayTitle, slug: repo.slug, pr: n, sha: nil,
                                     url: repo.slug.flatMap { slug in n.flatMap { GitLinks.pr(slug, $0) } },
                                     statKey: nil, date: s.modifiedDate))
            }
            if let ahead = badge.ahead, ahead > 0, !badge.isLanded {
                let base = repo.baseSha ?? ""
                let baseName = badge.base.map { b in b.firstIndex(of: "/").map { String(b[b.index(after: $0)...]) } ?? b }
                let pushed = badge.branch.map { repo.remote.contains($0) } ?? false
                pending.append(Pending(
                    id: top, title: s.displayTitle, branch: badge.branch, ahead: ahead,
                    statKey: tip.map { "d:\(base)...\($0)" }, commitsKey: tip.map { "c:\(base)..\($0)" },
                    url: pushed ? repo.slug.flatMap { slug in baseName.flatMap { b in badge.branch.flatMap { GitLinks.compare(slug, base: b, branch: $0) } } } : nil,
                    trouble: badge.trouble, dirty: badge.dirty))
            }
        }
        landed.sort { $0.date > $1.date }
        pending.sort { $0.ahead > $1.ahead }
        var card = Card()
        card.landed = Array(landed.prefix(landedLimit))
        card.moreLanded = max(0, landed.count - landedLimit)
        card.pending = Array(pending.prefix(pendingLimit))
        card.morePending = max(0, pending.count - pendingLimit)
        return card
    }

    /// The merges on base that brought this branch in: the tip itself, or a merge naming it.
    nonisolated private static func merges(of badge: GitBadge, tip: String?, in repo: Repo) -> [GitParse.Merge] {
        repo.merges.filter { m in
            if let tip, m.brought.contains(tip) { return true }
            guard let branch = badge.branch, let mb = m.branch else { return false }
            return mb == branch || branch.hasSuffix("/" + mb)
        }
    }

    /// Read the numbers a card shows that aren't cached yet (the first hover only). Each key
    /// is a sha range, so a cached value never goes stale.
    func load(_ card: Card, commitsFor pending: Pending? = nil) {
        var jobs: [(key: String, dir: String)] = []
        for l in card.landed {
            guard let key = l.statKey, stats[key] == nil, let dir = dir(forMerge: l.id) else { continue }
            jobs.append((key, dir))
        }
        for p in card.pending {
            guard let key = p.statKey, stats[key] == nil, let dir = trees[p.id]?.ref.top else { continue }
            jobs.append((key, dir))
        }
        if let p = pending, let key = p.commitsKey, commits[key] == nil, let dir = trees[p.id]?.ref.top {
            jobs.append((key, dir))
        }
        for job in jobs where loading.insert(job.key).inserted {
            let (key, dir) = job
            Task {
                let value = await Task.detached(priority: .userInitiated) { Self.read(key, in: dir) }.value
                loading.remove(key)
                switch value {
                case .stat(let s): stats[key] = s
                case .commits(let c): commits[key] = c
                case nil: break
                }
            }
        }
    }

    private enum Read: Sendable { case stat(GitParse.DiffStat), commits([Commit]) }

    nonisolated private static func read(_ key: String, in dir: String) -> Read? {
        let arg = String(key.dropFirst(2))
        switch key.prefix(2) {
        case "m:":
            guard let out = git(dir, ["diff", "--shortstat", "\(arg)^1...\(arg)^2"], timeout: 2) else { return nil }
            return .stat(GitParse.shortstat(out))
        case "d:":
            guard let out = git(dir, ["diff", "--shortstat", arg], timeout: 2) else { return nil }
            return .stat(GitParse.shortstat(out))
        case "c:":
            guard let out = git(dir, ["log", "--format=%h%x1f%s", "-n", "5", arg], timeout: 2) else { return nil }
            return .commits(out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\u{1f}", maxSplits: 1)
                return f.count == 2 ? Commit(sha: String(f[0]), subject: String(f[1])) : nil
            })
        default:
            return nil
        }
    }

    private func dir(forMerge sha: String) -> String? {
        repos.values.first { $0.merges.contains { $0.sha == sha } }?.dir
    }
}

/// An FSEvents stream on a repo's common git dir, reporting changed paths on a private queue.
private final class RefWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "frog.git.refs", qos: .utility)
    private let onChange: @Sendable ([String]) -> Void

    init(path: String, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<RefWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.onChange(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}

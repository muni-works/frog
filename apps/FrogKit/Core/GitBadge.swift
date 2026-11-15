import Foundation

/// A session's git summary for its sidebar row (docs/design/sidebar-git/README.md §1): commits
/// its branch carries that the base doesn't, whether it landed, whether its tree is dirty, and
/// whether a rebase or merge is stuck in it. Pure data; the Mac's `GitIndex` fills it from git.
struct GitBadge: Equatable, Sendable {
    enum Landed: Equatable, Sendable {
        case no
        /// The branch tip is in the base.
        case ancestor
        /// Every commit has a patch-equivalent in the base (`git cherry`: a squash or rebase).
        case patchEquivalent
        /// GitHub said its pull request merged (asked on an explicit refresh).
        case pr(Int)
    }

    enum Trouble: Equatable, Sendable {
        case rebasing, merging, cherryPicking
        case conflicts(Int)

        var words: String {
            switch self {
            case .rebasing: "rebasing"
            case .merging: "merging"
            case .cherryPicking: "cherry-picking"
            case .conflicts(let n): "\(n) conflict\(n == 1 ? "" : "s")"
            }
        }
    }

    /// The tree's top (canonical path): what aggregates dedupe on.
    var tree: String
    /// Nil when HEAD is detached.
    var branch: String?
    /// "origin/main"; nil when there's nothing to compare against.
    var base: String?
    /// Commits in `base..HEAD`; nil when unknown (no base yet).
    var ahead: Int?
    var behind = 0
    /// Files with uncommitted changes; nil when not read yet.
    var dirty: Int?
    var landed = Landed.no
    var trouble: Trouble?
    /// The repo's main checkout: its dirty files are everyone's there, not this row's.
    var mainCheckout = false
    /// HEAD's short sha, for a detached head's tooltip.
    var head: String?

    var detached: Bool { branch == nil }
    var isLanded: Bool { landed != .no && (ahead ?? 0) == 0 }

    /// What the row draws, given whether its session has settled (a running tree is always
    /// dirty, so the dot only means something once it's done). Nil: nothing to draw.
    func display(settled: Bool) -> Display? {
        let dot = settled && !mainCheckout && (dirty ?? 0) > 0
        let shownAhead = (ahead ?? 0) > 0 ? ahead : nil
        let d = Display(ahead: shownAhead, dirty: dot, landed: isLanded ? 1 : 0,
                        trouble: settled ? trouble : nil, detached: detached, leaf: true)
        return d.isEmpty ? nil : d
    }

    /// The row's glyphs: a branch glyph with the ahead count (and the dirty dot), a merge glyph
    /// with the landed count (a leaf shows the glyph alone), amber when stuck.
    struct Display: Equatable, Sendable {
        var ahead: Int?
        var dirty = false
        var landed = 0
        var trouble: Trouble?
        var detached = false
        /// One session's badge (the landed glyph without a number), not an aggregate.
        var leaf = false

        var showsBranch: Bool { ahead != nil || dirty || trouble != nil }
        var isEmpty: Bool { !showsBranch && landed == 0 }
    }

    /// The tooltip line: "frog/x · 17 ahead, 133 behind origin/main · clean".
    var summary: String {
        var parts = [branch ?? "detached at \(head ?? "HEAD")"]
        if let base {
            var counts = ["\(ahead ?? 0) ahead"]
            if behind > 0 { counts.append("\(behind) behind") }
            parts.append(counts.joined(separator: ", ") + " " + base)
        } else {
            parts.append("no base to compare")
        }
        if let trouble { parts.append(trouble.words) }
        if !mainCheckout, let dirty { parts.append(dirty == 0 ? "clean" : "\(dirty) uncommitted") }
        switch landed {
        case .no: break
        case .ancestor, .patchEquivalent: if (ahead ?? 0) == 0 { parts.append("landed") }
        case .pr(let n): if (ahead ?? 0) == 0 { parts.append("PR #\(n) merged") }
        }
        return parts.joined(separator: " · ")
    }
}

/// A group's badge (a manager, a done fold, a repo): the sum over its children's trees, each
/// tree counted once (§2 aggregation).
struct GitSummary: Equatable, Sendable {
    var ahead = 0
    var landed = 0
    /// A settled tree is dirty.
    var dirty = false
    /// A settled tree is stuck mid-rebase or merge.
    var trouble = false

    var isEmpty: Bool { ahead == 0 && landed == 0 && !dirty && !trouble }

    var display: GitBadge.Display? {
        let d = GitBadge.Display(ahead: ahead > 0 ? ahead : nil, dirty: dirty, landed: landed,
                                 trouble: trouble ? .rebasing : nil)
        return d.isEmpty ? nil : d
    }

    /// The summary over `items`: each session's badge and whether it settled. Trees shared by
    /// several sessions count once, settled only when every session in them is.
    static func of(_ items: [(badge: GitBadge, settled: Bool)]) -> GitSummary {
        var trees: [String: (badge: GitBadge, settled: Bool)] = [:]
        for item in items {
            if let seen = trees[item.badge.tree] {
                trees[item.badge.tree] = (seen.badge, seen.settled && item.settled)
            } else {
                trees[item.badge.tree] = item
            }
        }
        var out = GitSummary()
        for (badge, settled) in trees.values {
            if badge.mainCheckout && badge.branch != nil && badge.ahead == 0 { continue }
            if badge.isLanded {
                out.landed += 1
            } else {
                out.ahead += badge.ahead ?? 0
            }
            if settled && !badge.mainCheckout && (badge.dirty ?? 0) > 0 { out.dirty = true }
            if settled && badge.trouble != nil { out.trouble = true }
        }
        return out
    }
}

/// Which sessions a group row stands for in the attention tree: a manager's whole subtree, and
/// a done fold's folded children with theirs. The scope never changes these (§2).
enum GitRollup {
    /// Every session under `id` (itself included), through `children`.
    static func subtree(_ id: String, children: (String) -> [String]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        var stack = [id]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            stack.append(contentsOf: children(next))
        }
        return out
    }

    /// Each `.done` fold's members: its parent's children that aren't drawn as rows before it
    /// (those are the live ones; an open fold's members come after it). Keyed by the fold's
    /// parent (`AttentionTree.chiefFold` and `yoursFold` included).
    static func foldMembers(_ entries: [SessionNesting.Entry], children: (String) -> [String]) -> [String: [String]] {
        var before: Set<String> = []
        var out: [String: [String]] = [:]
        for e in entries {
            switch e {
            case .row(let s, _, _, _):
                before.insert(s.id)
            case .done(let parent, _, _, _, _):
                out[parent] = children(parent).filter { !before.contains($0) }
            }
        }
        return out
    }
}

/// What git prints, read into values. Pure, so tests pin the formats down.
enum GitParse {
    struct Ref: Equatable, Sendable {
        var sha: String
        var ahead: Int
        var behind: Int
    }

    /// `for-each-ref --format='%(objectname) %(refname) %(ahead-behind:<base>)' refs/heads`:
    /// branch (without `refs/heads/`) → tip, ahead, behind.
    static func aheadBehind(_ out: String) -> [String: Ref] {
        var refs: [String: Ref] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 4, let a = Int(f[2]), let b = Int(f[3]) else { continue }
            let name = f[1].hasPrefix("refs/heads/") ? String(f[1].dropFirst("refs/heads/".count)) : String(f[1])
            refs[name] = Ref(sha: String(f[0]), ahead: a, behind: b)
        }
        return refs
    }

    /// `status --porcelain=v2`: changed files (untracked included) and unmerged paths.
    static func status(_ out: String) -> (dirty: Int, conflicts: Int) {
        var dirty = 0, conflicts = 0
        for line in out.split(separator: "\n") {
            guard let c = line.first else { continue }
            switch c {
            case "1", "2", "?": dirty += 1
            case "u": dirty += 1; conflicts += 1
            default: break
            }
        }
        return (dirty, conflicts)
    }

    /// `.git/HEAD` (or a worktree's): its branch, or the sha it's detached at.
    static func head(_ text: String) -> (branch: String?, sha: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref: refs/heads/") { return (String(t.dropFirst("ref: refs/heads/".count)), nil) }
        return (nil, t.isEmpty ? nil : t)
    }

    /// The first line of a branch's reflog: the commit it was created at.
    static func created(_ reflog: String) -> String? {
        guard let first = reflog.split(separator: "\n").first else { return nil }
        let f = first.split(separator: " ")
        return f.count > 1 ? String(f[1]) : nil
    }

    /// A merge on the base's first-parent line.
    struct Merge: Equatable, Sendable {
        var sha: String
        /// Its parents after the first (what it brought in).
        var brought: [String]
        /// `Merge pull request #N from …`
        var pr: Int?
        /// The merged branch: `frog/x` from `Merge remote-tracking branch 'origin/frog/x'`, or
        /// the head of a pull request (`x` from `… from owner/x`).
        var branch: String?
        /// The pull request's title (the body's first line); nil for a local merge.
        var title: String?
        var date: Date
    }

    /// The field and record separators `merges` expects.
    static let mergeFormat = "%H%x1f%P%x1f%ct%x1f%s%x1f%b%x1e"

    /// `log <base> --first-parent --merges --format=<mergeFormat>`.
    static func merges(_ out: String) -> [Merge] {
        out.split(separator: "\u{1e}").compactMap { record in
            let f = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard f.count >= 4 else { return nil }
            let parents = f[1].split(separator: " ").map(String.init)
            guard parents.count >= 2 else { return nil }
            var m = Merge(sha: f[0], brought: Array(parents.dropFirst()), pr: nil, branch: nil, title: nil,
                          date: Date(timeIntervalSince1970: Double(f[2]) ?? 0))
            let subject = f[3]
            let body = f.count > 4 ? f[4] : ""
            if let r = subject.range(of: #"^Merge pull request #(\d+) from ([^\s]+)"#, options: .regularExpression) {
                let words = subject[r].split(separator: " ")
                m.pr = Int(words[3].dropFirst())
                let head = String(words[5])
                m.branch = head.split(separator: "/", maxSplits: 1).last.map(String.init)
                let line = body.split(separator: "\n").first.map(String.init)
                m.title = (line?.isEmpty ?? true) ? nil : line
            } else if let r = subject.range(of: #"^Merge (remote-tracking )?branch '([^']+)'"#, options: .regularExpression) {
                let quoted = subject[r].split(separator: "'")
                if quoted.count >= 2 {
                    var b = String(quoted[1])
                    if b.hasPrefix("origin/") { b = String(b.dropFirst("origin/".count)) }
                    m.branch = b
                }
            }
            return m
        }
    }

    struct DiffStat: Equatable, Sendable {
        var files = 0, added = 0, removed = 0
    }

    /// `diff --shortstat`: " 3 files changed, 645 insertions(+), 63 deletions(-)".
    static func shortstat(_ out: String) -> DiffStat {
        var s = DiffStat()
        for part in out.split(separator: ",") {
            let n = Int(part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first ?? "") ?? 0
            if part.contains("changed") { s.files = n }
            if part.contains("insertion") { s.added = n }
            if part.contains("deletion") { s.removed = n }
        }
        return s
    }

    /// `owner/repo` for a GitHub remote (ssh or https); nil for any other host.
    static func slug(remote: String) -> String? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"] {
            guard r.hasPrefix(prefix) else { continue }
            r = String(r.dropFirst(prefix.count))
            if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
            if r.hasSuffix("/") { r = String(r.dropLast()) }
            let parts = r.split(separator: "/")
            return parts.count == 2 ? r : nil
        }
        return nil
    }
}

/// GitHub pages for the hover card's rows, built from the remote alone (no API).
enum GitLinks {
    static func pr(_ slug: String, _ n: Int) -> URL? { URL(string: "https://github.com/\(slug)/pull/\(n)") }
    static func commit(_ slug: String, _ sha: String) -> URL? { URL(string: "https://github.com/\(slug)/commit/\(sha)") }
    /// `base` is the remote's branch ("main", not "origin/main").
    static func compare(_ slug: String, base: String, branch: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let b = branch.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/\(slug)/compare/\(base)...\(b)")
    }
}

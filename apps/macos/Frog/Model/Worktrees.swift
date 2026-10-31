import Foundation

/// One of a repo's worktrees, as `git worktree list --porcelain` reports it.
struct Worktree: Identifiable, Equatable, Sendable {
    let folder: URL
    /// The checked-out branch, nil for a detached HEAD.
    let branch: String?
    /// The commit it sits on (short), and whether files are dirty — for the row's subtitle.
    let sha: String
    let dirty: Bool
    /// The session whose engine holds the tree's lock, if one does.
    let owner: String?
    /// Whether this is the repo's main checkout (not a tree under `.frog/worktrees`).
    let isMain: Bool

    var id: URL { folder }
    /// The name workers know: the folder under `<repo>/.frog/worktrees`.
    var name: String { folder.lastPathComponent }
}

/// A repo's worktrees, read when the composer asks. All reads are plain `git` subprocesses,
/// off the main actor; the list is held for reuse so opening the menu doesn't re-run git.
@MainActor
@Observable
final class WorktreeIndex {
    /// The repo these worktrees belong to.
    let repo: URL
    private(set) var trees: [Worktree] = []
    /// The remote default branch a new tree starts from (`origin/main`), when known.
    private(set) var baseRef: String?

    init(repo: URL) {
        self.repo = repo
    }

    /// Read now, off the main thread. Cheap per call (a handful of git runs), and only asked
    /// for when the menu opens or after a create.
    func refresh() async {
        let repo = self.repo
        let parsed = await Task.detached { Self.read(repo) }.value
        trees = parsed.trees
        baseRef = parsed.base
    }

    /// All of it in one detached task: the list, each tree's dirtiness, and the base branch.
    /// Only frog's own trees show (`<repo>/.frog/worktrees/<name>`) plus the main checkout —
    /// the repo has 100+ trees of other tooling's making, and the menu would be noise.
    nonisolated static func read(_ repo: URL) -> (trees: [Worktree], base: String?) {
        // git resolves symlinks in its paths (`/tmp` → `/private/tmp`); the repo's own answer
        // (`rev-parse --show-toplevel`) is in the same terms, so compare against that.
        let top = (Git.run(repo, ["rev-parse", "--show-toplevel"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else { return ([], nil) }
        let repo = URL(fileURLWithPath: top)
        // "worktree <path>\nHEAD <sha>\nbranch refs/heads/<name>\n\n…": blank lines end each
        // record — keep them (split drops empties by default).
        let text = Git.run(repo, ["worktree", "list", "--porcelain"]) ?? ""
        var trees: [Worktree] = []
        var folder: URL?
        var sha = ""
        var branch: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { folder = URL(fileURLWithPath: String(line.dropFirst(9))) }
            else if line.hasPrefix("HEAD ") { sha = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7).dropFirst("refs/heads/".count)) }
            else if line.isEmpty, let at = folder {
                trees.append(Worktree(folder: at, branch: branch, sha: String(sha.prefix(7)), dirty: false, owner: nil, isMain: at == repo))
                folder = nil; branch = nil
            }
        }
        if let at = folder { // a list that doesn't end in a blank line
            trees.append(Worktree(folder: at, branch: branch, sha: String(sha.prefix(7)), dirty: false, owner: nil, isMain: at == repo))
        }
        // The menu's scope: the main checkout, then frog's own trees (`/worktrees/<name>`
        // directly under the repo). Trees elsewhere (other tooling's scratchpads) stay out.
        let own = repo.appending(path: ".frog/worktrees").path + "/"
        trees = trees.filter { $0.folder.path == repo.path || $0.folder.path.hasPrefix(own) }
        // Dirty + owner per tree, then the main checkout first.
        trees = trees.map { t -> Worktree in
            let status = Git.run(t.folder, ["status", "--porcelain"]) ?? ""
            let dirty = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let gitDir: URL? = t.isMain
                ? URL(fileURLWithPath: Git.run(t.folder, ["rev-parse", "--absolute-git-dir"]) ?? "")
                : URL(fileURLWithPath: Git.run(t.folder, ["rev-parse", "--git-dir"]) ?? "").standardizedFileURL
            let owner = gitDir.flatMap { SessionBroker.worktreeOwner(gitDir: $0) }
            return Worktree(folder: t.folder, branch: t.branch, sha: t.sha, dirty: dirty, owner: owner, isMain: t.isMain)
        }
        .sorted { $0.isMain && !$1.isMain }

        // The base a new tree forks from: the remote default (as SessionBroker picks it).
        let head = Git.run(repo, ["rev-parse", "--symbolic-full-name", "origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base: String?
        if let head, !head.isEmpty, head != "origin/HEAD" { base = head }
        if base == nil, let main = ["origin/main", "origin/master"].first(where: { Git.run(repo, ["rev-parse", "--verify", "--quiet", $0]) != nil }) {
            base = main
        }
        return (trees, base)
    }

    /// A fresh worktree like StartSession makes one: `.frog/worktrees/<name>` on `frog/<name>`,
    /// from the remote default. Returns the folder to start the session in.
    func create(named raw: String) async throws -> URL {
        let repo = self.repo
        let (dir, _, _) = try await Task.detached {
            try SessionBroker.makeWorktree(from: repo, name: raw)
        }.value
        await refresh()
        return dir
    }
}

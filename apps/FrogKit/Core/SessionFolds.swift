import Foundation

/// Rows for a session list: forks and resumes of the same worktree folded into one row — the
/// newest session of the branch, the rest behind a disclosure. Pure logic, so the sidebar and
/// the tests share it.
enum SessionFolds {
    /// A folded row: the session to show, the ones it absorbed, and whether the fold can open.
    struct Fold: Equatable, Sendable {
        var session: SessionInfo
        /// Older sessions of the same branch, newest first, behind the disclosure.
        var older: [SessionInfo]
        var folded: Bool { !older.isEmpty }
    }

    /// Fold sessions that run in the same worktree branch into one row each, keeping the
    /// newest and hiding the older ones behind its disclosure. A session is a resume of the
    /// branch when it works in the same worktree folder (`<repo>/.frog/worktrees/<name>` or
    /// `<repo>/.claude/worktrees/<name>`); forks declared in the header (`forkedFrom`) count
    /// too, whatever their folder. Everything else passes through unchanged, order kept.
    static func group(_ sessions: [SessionInfo]) -> [Fold] {
        var byWorktree: [String: [Int]] = [:]
        var byForkSource: [String: [Int]] = [:]
        for (i, s) in sessions.enumerated() {
            if let path = worktreePath(s.folder) { byWorktree[path, default: []].append(i) }
            if let fork = s.forkedFrom { byForkSource[fork.session, default: []].append(i) }
        }

        // Union-find over indices: same worktree, or forked (transitively) from the same root.
        var parent = Array(sessions.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Sessions in the same worktree folder are one branch.
        for (_, indices) in byWorktree where indices.count > 1 {
            for i in indices.dropFirst() { union(indices[0], i) }
        }
        // A fork joins its source's group when both are in this list.
        for (source, indices) in byForkSource {
            guard let s = sessions.firstIndex(where: { $0.id == source }) else { continue }
            for i in indices { union(s, i) }
        }

        var groups: [Int: [Int]] = [:]
        for i in sessions.indices { groups[root(i), default: []].append(i) }

        // A folded row's sessions, newest first (the list may not be sorted).
        var folds: [Fold] = []
        for i in sessions.indices where root(i) == i {
            let members = (groups[i] ?? []).map { sessions[$0] }
            let sorted = members.sorted { $0.modified > $1.modified }
            folds.append(Fold(session: sorted[0], older: Array(sorted.dropFirst())))
        }
        return folds.sorted { $0.session.modified > $1.session.modified }
    }

    /// The worktree folder path a session runs in, when it runs in one.
    static func worktreePath(_ folder: URL?) -> String? {
        guard let folder else { return nil }
        let path = folder.standardizedFileURL.path
        for marker in ["/.frog/worktrees/", "/.claude/worktrees/"] {
            if let r = path.range(of: marker) { return String(path[..<r.lowerBound]) + marker + folder.lastPathComponent }
        }
        return nil
    }
}

import Foundation

/// Which of the account's repos the where menu shows (docs/design/composer/spec.md, Where it
/// runs). One rule on both apps, pinned by docs/design/composer/repo-rank.json; the web's copy is
/// apps/web/src/repoRank.ts.
enum RepoRank {
    /// How many repos the menu lists before the rest go behind the search.
    static let limit = 6

    /// Every repo, best first: the current one, then the ones used in Frog (most recent first),
    /// then the rest by their last push on GitHub (newest first, never-pushed last, then by name).
    /// `pushed` is GitHub's ISO 8601 UTC stamp, so comparing the strings orders the times.
    /// GitHub names ignore case: a pasted "Ecto/Pond" is the account's "ecto/pond", one row, in
    /// the account's spelling.
    static func rank(current: String?, used: [String], repos: [(name: String, pushed: String?)]) -> [String] {
        let spelling = Dictionary(repos.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        var seen = Set<String>()
        func add(_ r: String?) {
            guard let r, !r.isEmpty, seen.insert(r.lowercased()).inserted else { return }
            out.append(spelling[r.lowercased()] ?? r)
        }
        add(current)
        used.forEach(add)
        let rest = repos.sorted { a, b in
            if a.pushed != b.pushed {
                guard let pa = a.pushed else { return false }
                guard let pb = b.pushed else { return true }
                return pa > pb
            }
            return a.name < b.name
        }
        rest.forEach { add($0.name) }
        return out
    }

    /// The rows to show for a search (empty: the best few) and how many matches didn't fit.
    static func pick(_ ranked: [String], query: String, limit: Int = limit) -> (shown: [String], more: Int) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? ranked : ranked.filter { $0.lowercased().contains(q) }
        return (Array(matches.prefix(limit)), max(0, matches.count - limit))
    }

    /// The one quiet line under a trimmed list; nil when nothing is hidden.
    static func moreLine(_ more: Int, searching: Bool) -> String? {
        guard more > 0 else { return nil }
        if searching { return "\(more) more \(more == 1 ? "match" : "matches"), keep typing" }
        return "\(more) more \(more == 1 ? "repo" : "repos"), type to search"
    }

    /// The repos used in Frog, most recent first: by each session's last turn (else its last update).
    static func used(_ sessions: [(repo: String, updated: Double, lastTurn: Double?)]) -> [String] {
        var seen = Set<String>()
        return sessions.sorted { ($0.lastTurn ?? $0.updated) > ($1.lastTurn ?? $1.updated) }
            .map(\.repo).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

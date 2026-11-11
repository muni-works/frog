import Foundation

/// The sidebar's started-by tree (a manager and the workers it started) as rows. Finished or
/// dead children fold under one "+N done" row per parent, so live work stands out. Pure logic,
/// so the sidebar and the tests share it.
enum SessionNesting {
    /// A row's state for nesting, most urgent first: children sort in this order (waiting on
    /// you, then running, then finished unseen, then failed and done).
    enum State: Int, Comparable, Sendable {
        case waiting, running, unread, failed, done

        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }

        /// Finished or dead: tucked under the parent's "+N done" row.
        var settled: Bool { self == .done || self == .failed }

        init(_ glyph: SessionEndGlyph) {
            switch glyph {
            case .waiting: self = .waiting
            case .running: self = .running
            case .unread: self = .unread
            case .failed: self = .failed
            case .idle: self = .done
            }
        }
    }

    /// How a parent's children stand, for its collapsed row: "4 running · 1 waiting".
    struct Counts: Equatable, Sendable {
        var waiting = 0, running = 0, unread = 0, failed = 0, done = 0

        var total: Int { waiting + running + unread + failed + done }

        mutating func add(_ state: State) {
            switch state {
            case .waiting: waiting += 1
            case .running: running += 1
            case .unread: unread += 1
            case .failed: failed += 1
            case .done: done += 1
            }
        }

        /// What's live first, then how the rest ended; nil without children.
        var summary: String? {
            let parts = [(running, "running"), (waiting, "waiting"), (unread, "new"), (failed, "failed"), (done, "done")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    enum Entry: Identifiable, Equatable {
        /// A session's row, how deep it sits, how its children stand, and whether they're
        /// collapsed into it.
        case row(SessionInfo, depth: Int, counts: Counts, collapsed: Bool)
        /// A parent's settled children, folded into one disclosure row at their depth.
        case done(parent: String, depth: Int, count: Int, failed: Int, open: Bool)

        var id: String {
            switch self {
            case .row(let s, _, _, _): s.id
            case .done(let parent, _, _, _, _): "done:" + parent
            }
        }
    }

    /// A top-level row and everything listed under it, in order.
    struct Block: Equatable {
        var root: SessionInfo
        var entries: [Entry]
    }

    /// `rows` split at its top-level rows, so each tree can be filed (under a day, say) whole.
    static func blocks(_ entries: [Entry]) -> [Block] {
        var out: [Block] = []
        for e in entries {
            if case .row(let s, 0, _, _) = e {
                out.append(Block(root: s, entries: [e]))
            } else if !out.isEmpty {
                out[out.count - 1].entries.append(e)
            }
        }
        return out
    }

    /// Deepest indent; deeper descendants line up with it.
    static let maxDepth = 4

    /// The ids of the entries (rows or "+N done") that are the last of their parent's children (nothing else at
    /// their depth before the tree climbs back out), whose guide line ends in an elbow.
    static func lastChildren(_ list: [Entry]) -> Set<String> {
        func depth(_ e: Entry) -> Int {
            switch e {
            case .row(_, let d, _, _): d
            case .done(_, let d, _, _, _): d
            }
        }
        var out: Set<String> = []
        for (i, e) in list.enumerated() {
            let d = depth(e)
            guard d > 0 else { continue }
            var last = true
            for next in list[(i + 1)...] {
                let nd = depth(next)
                if nd < d { break }
                if nd == d { last = false; break }
            }
            if last { out.insert(e.id) }
        }
        return out
    }

    /// A flat list in tree order, for lists that keep their own sections (the phone's):
    /// each id followed by the ones it started that are in the same list, indented one
    /// deeper (up to `maxDepth`). Order otherwise kept; a child whose parent isn't in the
    /// list stays where it was, as a root; a cycle can't lose a row.
    static func indented(_ ids: [String], parent: (String) -> String?) -> [(id: String, depth: Int)] {
        let present = Set(ids)
        var parentIn: [String: String] = [:]
        for id in ids {
            if let p = parent(id), p != id, present.contains(p) { parentIn[id] = p }
        }
        var out: [(id: String, depth: Int)] = []
        var placed: Set<String> = []
        func walk(_ id: String, _ depth: Int) {
            guard placed.insert(id).inserted else { return }
            out.append((id, depth))
            for c in ids where parentIn[c] == id { walk(c, min(depth + 1, maxDepth)) }
        }
        for id in ids where parentIn[id] == nil { walk(id, 0) }
        for id in ids where !placed.contains(id) { walk(id, 0) }
        return out
    }

    /// Rows in tree order: each session followed by the ones it started. A child counts as
    /// settled only when it and everything under it is (a quiet manager whose workers run
    /// stays up). Settled children collapse under a `.done` row unless their parent is in
    /// `openDone`; `keep` (the session on screen, say) is never tucked away. Children sort by
    /// state (`State`'s order), roots by `before`. A parent in `collapsed` shows none of its
    /// children, only their counts. With `foldQuiet`, so does a parent with nothing live under
    /// it (a quiet manager: one line, "6 done") until its done row is opened (`openDone`).
    ///
    /// - Parameters:
    ///   - parent: the session that started `id`, if any (only parents in `items` nest).
    ///   - state: a session's own state.
    ///   - before: the list's order, for roots and for children within a state.
    static func rows(
        _ items: [SessionInfo],
        parent: (String) -> String?,
        state: (SessionInfo) -> State,
        before: (SessionInfo, SessionInfo) -> Bool,
        openDone: Set<String> = [],
        keep: Set<String> = [],
        collapsed: Set<String> = [],
        foldQuiet: Bool = false
    ) -> [Entry] {
        let ids = Set(items.map(\.id))
        var children: [String: [SessionInfo]] = [:]
        var roots: [SessionInfo] = []
        for s in items {
            if let p = parent(s.id), p != s.id, ids.contains(p) {
                children[p, default: []].append(s)
            } else {
                roots.append(s)
            }
        }

        // A session's state with its subtree's most urgent one folded in.
        var memo: [String: State] = [:]
        var visiting: Set<String> = []
        func effective(_ s: SessionInfo) -> State {
            if let m = memo[s.id] { return m }
            guard visiting.insert(s.id).inserted else { return state(s) }
            let own = state(s)
            let sub = (children[s.id] ?? []).map(effective).min()
            let e = sub.map { $0.settled ? own : min(own, $0) } ?? own
            visiting.remove(s.id)
            memo[s.id] = e
            return e
        }

        // Whether `keep` reaches into a session's subtree (the one on screen sits under it).
        var keeps: [String: Bool] = [:]
        func holdsKept(_ s: SessionInfo, _ seen: Set<String> = []) -> Bool {
            if let k = keeps[s.id] { return k }
            guard !seen.contains(s.id) else { return false }
            let k = keep.contains(s.id) || (children[s.id] ?? []).contains { holdsKept($0, seen.union([s.id])) }
            keeps[s.id] = k
            return k
        }

        var out: [Entry] = []
        var placed: Set<String> = []
        // Tucked away, but placed: a cycle can't surface them elsewhere.
        func hide(_ x: SessionInfo) {
            guard placed.insert(x.id).inserted else { return }
            (children[x.id] ?? []).forEach(hide)
        }
        func walk(_ s: SessionInfo, _ depth: Int) {
            guard placed.insert(s.id).inserted else { return }
            let kids = (children[s.id] ?? []).filter { !placed.contains($0.id) }
            var counts = Counts()
            kids.forEach { counts.add(effective($0)) }
            // A quiet parent (nothing live under it, nothing kept) folds to its counts unless
            // its done row was opened.
            let quiet = foldQuiet && effective(s).settled && !openDone.contains(s.id)
                && !kids.contains(where: { holdsKept($0) })
            let folded = (collapsed.contains(s.id) || quiet) && !kids.isEmpty
            out.append(.row(s, depth: depth, counts: counts, collapsed: folded))
            if folded { kids.forEach(hide); return }
            let next = min(depth + 1, maxDepth)
            // Most urgent first; the list's order within a state.
            let ordered = kids.sorted { a, b in
                let (ea, eb) = (effective(a), effective(b))
                return ea != eb ? ea < eb : before(a, b)
            }
            let active = ordered.filter { !effective($0).settled || keep.contains($0.id) }
            let settled = ordered.filter { effective($0).settled && !keep.contains($0.id) }
            active.forEach { walk($0, next) }
            guard !settled.isEmpty else { return }
            let open = openDone.contains(s.id)
            let failed = settled.count(where: { effective($0) == .failed })
            out.append(.done(parent: s.id, depth: next, count: settled.count, failed: failed, open: open))
            if open {
                settled.forEach { walk($0, next) }
            } else {
                settled.forEach(hide)
            }
        }
        roots.sorted(by: before).forEach { walk($0, 0) }
        // A parent cycle leaves sessions no root reaches: list them as roots, not lose them.
        items.sorted(by: before).filter { !placed.contains($0.id) }.forEach { walk($0, 0) }
        return out
    }
}

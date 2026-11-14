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

        var depth: Int {
            switch self {
            case .row(_, let d, _, _): d
            case .done(_, let d, _, _, _): d
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

    /// How deep a row sits and what its guide draws: the rails left of it and whether its own
    /// column ends in an elbow. One model for every list, so the tree's geometry can't drift
    /// between the two-line and compact sidebars.
    struct Guide: Equatable, Sendable {
        var depth: Int
        /// One per column left of the row's own, outermost first: `rails[c]` draws a vertical
        /// through column `c` (an ancestor there has more siblings further down).
        var rails: [Bool]
        /// The last of its parent's children: its own column stops in an elbow (a file tree's └).
        /// When false the column carries on to the next sibling.
        var last: Bool
        /// The row's children are listed right below it, so its own column runs on past the
        /// elbow down to them. False for a leaf, and for a collapsed parent: the elbow ends it.
        var continues: Bool

        static let root = Guide(depth: 0, rails: [], last: true, continues: false)

        init(depth: Int, rails: [Bool], last: Bool, continues: Bool = false) {
            self.depth = depth
            self.rails = rails
            self.last = last
            self.continues = continues
        }

        func rail(_ column: Int) -> Bool {
            column >= 0 && column < rails.count && rails[column]
        }
    }

    /// The guide for every row, by id, from the depths in tree order.
    ///
    /// Column `c` is the vertical between a depth-`c` row and what hangs under it; a row at
    /// depth `d` owns column `d - 1` (its elbow), and the columns left of that (`0 ..< d - 1`)
    /// are its ancestors'. An ancestor's column carries on past this row exactly when a later
    /// row sits deeper still with nothing shallower in between — that is, when that ancestor
    /// has more children to come.
    static func guides(_ depths: [(id: String, depth: Int)]) -> [String: Guide] {
        var out: [String: Guide] = [:]
        for (i, row) in depths.enumerated() {
            let d = row.depth
            let below = depths[(i + 1)...]
            // Its own column stops at its last sibling; a shallower row closes the subtree.
            var last = true
            for next in below {
                if next.depth < d { break }
                if next.depth == d { last = false; break }
            }
            // Each ancestor's column carries on while something still hangs below it. In tree
            // order the next row decides every column at once: if it sits deeper than the
            // column, that subtree is still open; if not, it has closed.
            let next = depths.indices.contains(i + 1) ? depths[i + 1].depth : 0
            let rails = (0..<max(d - 1, 0)).map { next > $0 }
            // Its children are listed right under it when the next row is one level deeper;
            // a fold hides them, so it has nothing below and its elbow ends the column.
            let continues = next > d
            out[row.id] = Guide(depth: d, rails: rails, last: last, continues: continues)
        }
        return out
    }

    /// The guide for each entry of a tree list.
    static func guides(_ list: [Entry]) -> [String: Guide] {
        guides(list.map { ($0.id, $0.depth) })
    }

    /// A flat list in tree order, for lists that keep their own sections (the phone's):
    /// each id followed by the ones it started that are in the same list, indented one
    /// deeper. Order otherwise kept; a child whose parent isn't in the list stays where it
    /// was, as a root; a cycle can't lose a row.
    ///
    /// No depth cap: a fifth-level worker sits visibly deeper than a fourth (the sidebar
    /// indents by real depth and stops only where the width runs out, `AttentionMetrics`).
    /// A cap here would line two levels up on the same rail with no way to tell them apart.
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
            for c in ids where parentIn[c] == id { walk(c, depth + 1) }
        }
        for id in ids where parentIn[id] == nil { walk(id, 0) }
        for id in ids where !placed.contains(id) { walk(id, 0) }
        return out
    }

    /// Rows in tree order: each session followed by the ones it started, and nothing in
    /// between. Expanding a session shows its children — finished ones included — with no
    /// second fold inside it (a "+N done" row under a parent was one accordion too many).
    /// A child counts as settled only when it and everything under it is (a quiet manager
    /// whose workers run stays up). Children sort by state (`State`'s order), roots by
    /// `before`. A parent in `collapsed` shows none of its children, only their counts; with
    /// `foldQuiet`, so does a quiet parent (settled, nothing live or kept under it) until it's
    /// in `opened` — the whole of a quiet manager is one line until you open it.
    ///
    /// - Parameters:
    ///   - parent: the session that started `id`, if any (only parents in `items` nest).
    ///   - state: a session's own state.
    ///   - before: the list's order, for roots and for children within a state.
    ///   - opened: parents whose quiet fold the person has opened.
    static func rows(
        _ items: [SessionInfo],
        parent: (String) -> String?,
        state: (SessionInfo) -> State,
        before: (SessionInfo, SessionInfo) -> Bool,
        opened: Set<String> = [],
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
            // A quiet parent (nothing live under it, nothing kept) folds to its counts until the
            // person opens it.
            let quiet = foldQuiet && effective(s).settled && !opened.contains(s.id)
                && !kids.contains(where: { holdsKept($0) })
            let folded = (collapsed.contains(s.id) || quiet) && !kids.isEmpty
            out.append(.row(s, depth: depth, counts: counts, collapsed: folded))
            if folded { kids.forEach(hide); return }
            // Real depth, uncapped: the row's guide says how deep it sits, and the view
            // decides how much width it can spend on that (see `AttentionMetrics`).
            let next = depth + 1
            // Most urgent first; the list's order within a state. Settled children are rows
            // like any other: there's no second fold inside a session.
            kids.sorted { a, b in
                let (ea, eb) = (effective(a), effective(b))
                return ea != eb ? ea < eb : before(a, b)
            }.forEach { walk($0, next) }
        }
        roots.sorted(by: before).forEach { walk($0, 0) }
        // A parent cycle leaves sessions no root reaches: list them as roots, not lose them.
        items.sorted(by: before).filter { !placed.contains($0.id) }.forEach { walk($0, 0) }
        return out
    }
}

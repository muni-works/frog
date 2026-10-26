import Foundation

/// The sidebar's attention tree (docs/design/sidebar-refactor.md §5): the started-by tree
/// rooted at the chief as the skeleton, a needs-you lens above it, a scope that hides settled
/// work, and the root sessions you started yourself below. Pure logic over `SessionNesting`,
/// so the sidebar, the quick-switch shortcuts and the tests read the same tree.
enum AttentionTree {
    /// How much settled work the tree shows.
    enum Scope: String, CaseIterable, Sendable {
        /// Live children only; settled ones fold into "N done · k failed", quiet managers to
        /// one line.
        case live
        /// Also what settled today; older work folds into "N earlier".
        case today
        /// Everything not archived.
        case all

        var title: String {
            switch self {
            case .live: "Live"
            case .today: "Today"
            case .all: "All"
            }
        }
    }

    /// The `.done` fold of the chief's own finished leaves ("N done by chief").
    static let chiefFold = "chief:"
    /// The `.done` fold of your settled root sessions.
    static let yoursFold = "yours:"

    struct Layout: Equatable {
        /// Every session blocked on you, oldest first. A lens: each also keeps its tree place.
        var needsYou: [SessionInfo] = []
        /// Managers (anything that started sessions) and the chief's live leaves, nested.
        var org: [SessionNesting.Entry] = []
        /// Root sessions you started yourself.
        var yours: [SessionNesting.Entry] = []

        /// The top-level rows, in the order they're drawn: what ⌘1…9 count.
        var topLevels: [SessionInfo] {
            (org + yours).compactMap { e in
                if case .row(let s, 0, _, _) = e { return s } else { return nil }
            }
        }
    }

    /// The tree for `items` (not archived, the chief included or not).
    ///
    /// - Parameters:
    ///   - parent: who started a session (`Library.parents`, branch folds applied).
    ///   - chief: the chief of staff: its children are the top level, it's drawn as the tile.
    ///   - recent: settled today, for `.today`.
    ///   - openDone: open folds — parents' done rows, `chiefFold`, `yoursFold`.
    ///   - keep: never folded away (the session on screen).
    static func layout(
        _ items: [SessionInfo],
        parent: (String) -> String?,
        chief: String?,
        state: (SessionInfo) -> SessionNesting.State,
        before: (SessionInfo, SessionInfo) -> Bool,
        scope: Scope,
        recent: (SessionInfo) -> Bool = { _ in false },
        openDone: Set<String> = [],
        keep: Set<String> = [],
        collapsed: Set<String> = []
    ) -> Layout {
        var out = Layout()
        out.needsYou = items.filter { state($0) == .waiting }
            .sorted { $0.modified != $1.modified ? $0.modified < $1.modified : $0.id < $1.id }

        let tree = items.filter { $0.id != chief }
        // What survives the scope: the on-screen session, and today's or everything.
        let shown: Set<String> = switch scope {
        case .live: keep
        case .today: keep.union(tree.filter(recent).map(\.id))
        case .all: Set(tree.map(\.id))
        }
        let up: (String) -> String? = { id in
            let p = parent(id)
            return p == chief ? nil : p
        }
        let entries = SessionNesting.rows(
            tree, parent: up, state: state, before: before,
            openDone: openDone, keep: shown, collapsed: collapsed, foldQuiet: scope != .all)

        var chiefLeaves: [SessionInfo] = []
        var yourLeaves: [SessionInfo] = []
        for block in SessionNesting.blocks(entries) {
            guard case .row(_, _, let counts, _) = block.entries.first else { continue }
            if counts.total > 0 {
                out.org += block.entries
            } else if chief != nil, parent(block.root.id) == chief {
                // A leaf the chief started: in the org while live, else in its done fold.
                if !state(block.root).settled || shown.contains(block.root.id) {
                    out.org += block.entries
                } else {
                    chiefLeaves.append(block.root)
                }
            } else {
                // Yours: live and failed show in every scope.
                if state(block.root) != .done || shown.contains(block.root.id) {
                    out.yours += block.entries
                } else {
                    yourLeaves.append(block.root)
                }
            }
        }
        out.org += fold(chiefLeaves, key: chiefFold, state: state, open: openDone.contains(chiefFold))
        out.yours += fold(yourLeaves, key: yoursFold, state: state, open: openDone.contains(yoursFold))
        return out
    }

    /// Top-level settled leaves as one `.done` row, followed by them when it's open.
    private static func fold(_ leaves: [SessionInfo], key: String, state: (SessionInfo) -> SessionNesting.State,
                             open: Bool) -> [SessionNesting.Entry] {
        guard !leaves.isEmpty else { return [] }
        let failed = leaves.count(where: { state($0) == .failed })
        var out: [SessionNesting.Entry] = [.done(parent: key, depth: 0, count: leaves.count, failed: failed, open: open)]
        if open { out += leaves.map { .row($0, depth: 0, counts: .init(), collapsed: false) } }
        return out
    }

    /// Search: the sessions that match, plus their ancestors so each match keeps its context.
    static func matching(_ items: [SessionInfo], parent: (String) -> String?,
                         matches: (SessionInfo) -> Bool) -> [SessionInfo] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keep: Set<String> = []
        for s in items where matches(s) {
            var at: String? = s.id
            while let id = at, byId[id] != nil, keep.insert(id).inserted { at = parent(id) }
        }
        return items.filter { keep.contains($0.id) }
    }

    /// Whether `query` (lowercased, trimmed) matches a session: title, first input, folder or
    /// worktree, as the sidebar's search always has.
    static func matches(_ s: SessionInfo, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [s.title, s.firstInput, s.folder?.lastPathComponent].contains { $0?.lowercased().contains(query) == true }
    }
}

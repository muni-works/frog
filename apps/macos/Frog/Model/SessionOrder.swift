import Foundation

/// The sidebar's top-level rows, in its chosen order, as the quick-switch shortcuts (⌘1…9,
/// ⇧⌘]/⇧⌘[) step through them. Cached: it used to be derived in `WorkspaceView.body` — the
/// window root — so every body pass re-walked and re-sorted the whole listing (the org tree
/// twice), and the root's invalidations reached the sidebar with it. The inputs (sessions,
/// pins, archive, parents, grouping) change on listing and user action, not on a streamed
/// delta, so the cache invalidates only then.
@MainActor
final class SessionOrder {
    static let shared = SessionOrder()

    /// One entry per set of inputs: each window asks with its own current session (and maybe
    /// its own grouping), so a single slot would flip between them. Not observable on purpose:
    /// it's read and written from `WorkspaceView.body`, and an observable cache written in one
    /// window's body invalidated every other window's, which rewrote it — two windows (File >
    /// Open Folder… beside a chat) re-rendered each other until AppKit gave up its layout pass
    /// ("more Update Constraints in Window passes than there are views in the window") and
    /// crashed. The body still tracks what `derive` reads off the `Library`.
    private var cache: [String: [SessionInfo]] = [:]

    private init() {
        Library.shared.onOrderInvalidated = { [weak self] in self?.cache.removeAll() }
    }

    /// The order for a grouping: re-derived only when its inputs changed.
    static func order(group: SessionList.Grouping, sort: SessionList.Sort, scope: AttentionTree.Scope,
                      current: String?) -> [SessionInfo] {
        shared.get(group: group, sort: sort, scope: scope, current: current)
    }

    private func get(group: SessionList.Grouping, sort: SessionList.Sort, scope: AttentionTree.Scope,
                     current: String?) -> [SessionInfo] {
        let library = Library.shared
        let key = "\(library.sessions.count)|\(library.pinned.count)|\(library.archived.count)|\(library.parents.count)|\(group.rawValue)|\(sort.rawValue)|\(scope.rawValue)|\(current ?? "-")"
        if let hit = cache[key], !hit.isEmpty { return hit }
        let order = derive(group: group, sort: sort, scope: scope, current: current)
        // A few windows' worth; the listing moving clears it anyway.
        if cache.count > 16 { cache.removeAll() }
        cache[key] = order
        return order
    }

    private func derive(group: SessionList.Grouping, sort: SessionList.Sort, scope: AttentionTree.Scope,
                        current: String?) -> [SessionInfo] {
        let library = Library.shared
        if group == .org {
            // The attention tree: what needs you, then the org's top-level rows, then yours —
            // the chief first only with the flag on.
            let tree = SessionList.attention(library, sort: sort, scope: scope, current: current)
            return (FeatureFlags.chief ? [library.chiefSession].compactMap(\.self) : []) + tree.layout.topLevels
        }
        let active = library.sessions.filter { !library.archived.contains($0.id) }
        let pins = active.filter { library.pinned.contains($0.id) }
        let unpinned = active.filter { !$0.isChat && !library.pinned.contains($0.id) && $0.folder != nil }
        let byPath = Dictionary(grouping: unpinned) { home(of: $0).standardizedFileURL.path }
        let projects = byPath.values
            .map { items in items.sorted { $0.modified > $1.modified } }
            .sorted { ($0.first?.modified ?? 0) > ($1.first?.modified ?? 0) }
        let chats = active.filter { $0.isChat && !library.pinned.contains($0.id) }
        return pins + projects.flatMap(\.self) + chats.sorted { $0.modified > $1.modified }
    }

    /// The folder a session is filed under: its own, or (for one started by another session,
    /// say in a worktree) its topmost parent's repo (the sidebar's `home`).
    private func home(of s: SessionInfo) -> URL {
        var current = s
        var seen: Set<String> = [s.id]
        while let p = Library.shared.parents[current.id], !seen.contains(p),
              let parent = Library.shared.sessions.first(where: { $0.id == p }), parent.folder != nil, !parent.isChat {
            seen.insert(p)
            current = parent
        }
        return SessionList.repoRoot(current.folder ?? s.folder!)
    }
}

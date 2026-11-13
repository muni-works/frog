import Foundation

/// Archiving a session from a view of it: the one place that decides whether the view follows.
///
/// The rule: archiving the session on screen clears the view to a new one, and archiving any
/// other session leaves the user where they are. Unarchiving never navigates — you're in the
/// archive, restoring things — and neither does an archive nobody asked for in a view: the
/// `ArchiveSession` tool, the phone's row menu, and the quiet chats that archive themselves.
/// Those call `Library.setArchived` directly and never come through here, which is what keeps
/// them from moving a view. Everything that archives from a view calls `archive(_:from:)`, so a
/// fifth call site cannot get the rule wrong by not knowing it.
enum ArchiveNav {
    /// The pure decision, testable with no window, workspace or engine: a view follows the
    /// archive only when the archived session is the one it is showing.
    static func shouldForward(afterArchiving id: String, current: String?) -> Bool {
        guard let current else { return false }  // nothing on screen: nowhere to forward from
        return id == current
    }

    /// Archive `id`, and when `workspace` was showing it, clear the view. `forward` is the
    /// navigation itself, injectable so a test can watch it without an engine.
    @MainActor
    static func archive(_ id: String, from workspace: Workspace?,
                        forward: (Workspace) -> Void = { $0.newSession() }) {
        let follows = workspace.map { shouldForward(afterArchiving: id, current: $0.showing) } ?? false
        Library.shared.setArchived(id, true)
        guard follows, let workspace else { return }
        forward(workspace)
    }
}

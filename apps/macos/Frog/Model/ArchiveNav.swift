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
    ///
    /// The engine goes first. A session in a worktree holds that worktree's lock, and
    /// `Workspace.start` refuses to spawn in a folder another engine owns — so navigating
    /// straight to a new session put the refusal on screen instead of a new conversation:
    /// "one engine per worktree, so two sessions never mix uncommitted work". Stopping what was
    /// on screen releases the lock, and the view moves on once it's actually free.
    @MainActor
    static func archive(_ id: String, from workspace: Workspace?,
                        forward: ((Workspace) -> Void)? = nil) {
        let follows = workspace.map { shouldForward(afterArchiving: id, current: $0.showing) } ?? false
        // Taken before the archive lands: this is the conversation being cleared.
        let leaving = follows ? workspace?.conversation : nil
        Library.shared.setArchived(id, true)
        guard follows, let workspace else { return }
        if let forward { return forward(workspace) }
        clear(workspace, after: leaving)
    }

    /// Stop the engine that was on screen, then open a new session once its worktree is free.
    @MainActor
    private static func clear(_ workspace: Workspace, after leaving: Conversation?) {
        // Stopped outright rather than through `Workspace.stop`: that keeps a session with
        // background work alive, which is right when a window closes and wrong here — the
        // person archived it, so its worktree is the new session's.
        leaving?.stop(reason: "archived")
        let folder = workspace.folder
        Task { @MainActor in
            // The engine releases the lock as it exits. Bounded: if it somehow doesn't, the
            // refusal explains itself rather than the click doing nothing.
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline,
                  Workspace.worktreeOwner(of: folder, resumed: nil) != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            workspace.newSession()
        }
    }
}

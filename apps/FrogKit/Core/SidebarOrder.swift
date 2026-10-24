import Foundation

/// How the quick-switch shortcuts (⌘1…9, ⇧⌘] / ⇧⌘[) read the sidebar: which conversation is
/// the Nth one, and which is next or previous. The sidebar shows conversations as top-level
/// rows (a fold head, a branch, a manager) with their started-by children nested under them;
/// the shortcuts count top-level rows, the same ones a click targets first, so a child's row
/// never steals a digit from its parent.
enum SidebarOrder {
    /// The session the Nth shortcut (1-based) opens, from the sidebar's rows. Nil when there's
    /// no such row. Row 9 means the last one, Safari-style, when the list is longer.
    static func session(at index: Int, topLevels: [SessionInfo]) -> SessionInfo? {
        guard index >= 1 else { return nil }
        if index == 9 { return topLevels.last }
        guard index <= topLevels.count else { return nil }
        return topLevels[index - 1]
    }

    /// The next or previous conversation in sidebar order, wrapping. `topLevels` in the order
    /// the sidebar shows them; `current` is the one on screen. Nil when there's nothing to
    /// switch to.
    static func neighbor(of current: String?, in topLevels: [SessionInfo], step: Int) -> SessionInfo? {
        guard !topLevels.isEmpty else { return nil }
        let at = current.flatMap { id in topLevels.firstIndex { $0.id == id } }
        // Not on screen (or nothing at all): the first step enters the list from the end.
        let i = (at ?? (step > 0 ? -1 : 0)) + step
        return topLevels[(i % topLevels.count + topLevels.count) % topLevels.count]
    }
}

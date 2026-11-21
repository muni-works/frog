#if DEBUG
import Foundation

/// Counters for the sidebar's hover tests (SidebarHoverBadgeTests): a body that draws a git
/// badge bumps `badgeBodies`, so a test can see the badge enter and leave the layout without
/// walking the accessibility tree. Debug builds only.
@MainActor
enum SidebarProbe {
    /// Only this session's row counts. Every row bumps the same statics, so without it a row
    /// left alive by an earlier test (its window still ordered in, already expanded) counted
    /// into the next test's "before the expand" (2026-11-20: 37 of 80 runs of the class, 20
    /// iterations alone).
    static var session: String?
    /// Compact row bodies built (`CompactSessionRow`).
    static var rowBodies = 0
    /// Git badge bodies built (`GitBadgeView`), wherever it sits.
    static var badgeBodies = 0
    /// Row bodies built with the title expanded (hover's 450 ms have passed).
    static var expandedBodies = 0
    /// Git badge bodies built in a row whose title is expanded: the badge surviving the hover.
    static var expandedBadgeBodies = 0
    /// When the row's hover task began its 450 ms wait, and when it expanded the title: a test
    /// checks the wait against these rather than against its own guess of the clock.
    static var hoverStarted: Date?
    static var expandedAt: Date?

    static func counts(_ id: String) -> Bool { session == nil || session == id }

    static func reset(session: String? = nil) {
        self.session = session
        rowBodies = 0
        badgeBodies = 0
        expandedBodies = 0
        expandedBadgeBodies = 0
        hoverStarted = nil
        expandedAt = nil
    }
}
#endif

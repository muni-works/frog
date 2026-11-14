#if DEBUG
/// Counters for the sidebar's hover tests (SidebarHoverBadgeTests): a body that draws a git
/// badge bumps `badgeBodies`, so a test can see the badge enter and leave the layout without
/// walking the accessibility tree. Debug builds only.
@MainActor
enum SidebarProbe {
    /// Compact row bodies built (`CompactSessionRow`).
    static var rowBodies = 0
    /// Git badge bodies built (`GitBadgeView`), wherever it sits.
    static var badgeBodies = 0
    /// Row bodies built with the title expanded (hover's 450 ms have passed).
    static var expandedBodies = 0

    static func reset() {
        rowBodies = 0
        badgeBodies = 0
        expandedBodies = 0
    }
}
#endif

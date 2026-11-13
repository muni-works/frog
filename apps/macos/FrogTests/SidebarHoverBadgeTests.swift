import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The compact row's git badge must survive the hover it sits under: information must not be
/// hover-only. A badge that pops out when the title expands reads as a bug — reported twice
/// (2026-11-13). The row is driven the way a real pointer drives it: seeded hovered, its own
/// 450 ms task expands the title, and the probe (SidebarProbe) witnesses the badge's body.
@MainActor
final class SidebarHoverBadgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Library.shared.unstage()
        GitIndex.shared.unstage()
        SidebarProbe.reset()
    }

    override func tearDown() {
        Library.shared.unstage()
        GitIndex.shared.unstage()
        super.tearDown()
    }

    /// A settled session with commits ahead, so its badge has something to show.
    private func stage() -> SessionInfo {
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let s = SessionInfo(id: "hover", modified: t, created: t - 600_000, model: "x",
                            firstInput: nil, title: "sidebar hover badge", end: .complete, forkedFrom: nil,
                            cwd: "/Users/cam/Developer/frog/.frog/worktrees/hover")
        Library.shared.stage(sessions: [s], live: [:])
        GitIndex.shared.stage([
            "hover": GitBadge(tree: "/Users/cam/Developer/frog/.frog/worktrees/hover", branch: "frog/sidebar-hover-badge",
                              base: "origin/main", ahead: 3, behind: 0, dirty: 0, landed: .no, trouble: nil),
        ], card: nil, stats: [:])
        return s
    }

    /// A pointer parked on the row.
    private func hoveredRow(_ session: SessionInfo) -> some View {
        HStack(spacing: 0) {
            CompactSessionRow(session: session, selected: false, live: nil, depth: 0, git: GitTreeBadges.leaf(
                session, members: [session], settled: true, open: { _ in }
            ), open: {}, menu: { EmptyView() }, hovering: true)
            Color.clear.frame(width: 1) // room for the menu button the hover shows
        }
        .frame(width: 300, height: 32)
        .background(.background)
    }

    /// The badge is still in the row after the hover's 450 ms have passed and the title has
    /// expanded. Before the fix (`if let git, !expandTitle`) the badge dropped from the layout
    /// the moment the title expanded: `expandedBodies` incremented with no badge body behind it.
    func testBadgeStaysInTheRowWhileHovered() throws {
        let s = stage()
        let host = NSHostingView(rootView: hoveredRow(s))
        host.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: 32))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // The row's task needs the main loop to run: to fire, to sleep its 450 ms, and to set
        // expandTitle — the same path a real pointer takes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let earlyBadge = SidebarProbe.badgeBodies
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(SidebarProbe.expandedBodies > 0,
                      "the row never expanded its title, so this test proved nothing")
        XCTAssertGreaterThan(SidebarProbe.badgeBodies, earlyBadge,
                             "the badge left the row when the title expanded under the pointer")
    }
}

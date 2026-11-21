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
    /// Each test's window, closed in tearDown. One left ordered in keeps its row alive: an
    /// expanded row from the test before kept building bodies into the shared probe, so the
    /// next test saw "expanded" before its own 450 ms (37 of 80 local runs, 2026-11-20).
    private var windows: [NSWindow] = []
    private var shownAt = Date() // PROBE

    override func setUp() {
        super.setUp()
        Library.shared.unstage()
        GitIndex.shared.unstage()
        SidebarProbe.reset()
    }

    override func tearDown() {
        do { // PROBE
            let f = { (d: Date?) in d.map { String(format: "%.3f", $0.timeIntervalSince(self.shownAt)) } ?? "nil" }
            NSLog("HOVERPROBE %@ started=%@ expanded=%@ bodies=%d expandedBodies=%d now=%@ load=%.1f", name, f(SidebarProbe.hoverStarted), f(SidebarProbe.expandedAt), SidebarProbe.rowBodies, SidebarProbe.expandedBodies, f(Date()), TestRunner.loadPerCore)
        }
        for w in windows {
            w.contentView = nil
            w.close()
        }
        windows = []
        SidebarProbe.reset()
        Library.shared.unstage()
        GitIndex.shared.unstage()
        super.tearDown()
    }

    /// A settled session with commits ahead, so its badge has something to show. Its id is the
    /// test's own, and the probe counts only that row.
    private func stage(title: String = "sidebar hover badge") -> SessionInfo {
        let id = "hover-\(UUID().uuidString)"
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let s = SessionInfo(id: id, modified: t, created: t - 600_000, model: "x",
                            firstInput: nil, title: title, end: .complete, forkedFrom: nil,
                            cwd: "/Users/cam/Developer/frog/.frog/worktrees/hover")
        Library.shared.stage(sessions: [s], live: [:])
        GitIndex.shared.stage([
            id: GitBadge(tree: "/Users/cam/Developer/frog/.frog/worktrees/hover", branch: "frog/sidebar-hover-badge",
                         base: "origin/main", ahead: 3, behind: 0, dirty: 0, landed: .no, trouble: nil),
        ], card: nil, stats: [:])
        SidebarProbe.reset(session: id)
        return s
    }

    /// A pointer parked on the row (`hovering`), or one at rest.
    private func hoveredRow(_ session: SessionInfo, hovering: Bool = true) -> some View {
        HStack(spacing: 0) {
            CompactSessionRow(session: session, selected: false, live: nil, depth: 0, git: GitTreeBadges.leaf(
                session, members: [session], settled: true, open: { _ in }
            ), open: {}, menu: { EmptyView() }, hovering: hovering)
            Color.clear.frame(width: 1) // room for the menu button the hover shows
        }
        .frame(width: 300, height: 32)
        .background(.background)
    }

    private func show(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: 32))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderInForTest()
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        shownAt = Date() // PROBE
        return host
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The row's task needs the main loop to run: to fire, to sleep its 450 ms, and to set
    /// expandTitle — the same path a real pointer takes. Waited for, not guessed: a fixed 0.6 s
    /// or 0.7 s pause after the window is up is a guess at when the task started.
    @discardableResult
    private func waitForExpand() -> Bool {
        let deadline = Date().addingTimeInterval(3 * TestRunner.slack)
        while Date() < deadline, SidebarProbe.expandedBodies == 0 { pump(0.02) }
        // A few more frames, so the expanded row's later bodies (the snappy animation) count too.
        pump(0.25)
        return SidebarProbe.expandedBodies > 0
    }

    /// Where the hover task got to, for a failure message: it never started, it set the state but
    /// no expanded body was built (SwiftUI didn't re-render), or it expanded late.
    private var hoverState: String {
        let load = String(format: "load %.1f per core", TestRunner.loadPerCore)
        guard let s = SidebarProbe.hoverStarted else { return "the hover task never started; \(load)" }
        guard let e = SidebarProbe.expandedAt else {
            return "hover task started \(String(format: "%.2f", Date().timeIntervalSince(s))) s ago, never expanded; \(load)"
        }
        let after = String(format: "%.3f", e.timeIntervalSince(s))
        guard SidebarProbe.expandedBodies > 0 else {
            return "expanded \(after) s after the hover task started, but no expanded body was built in \(String(format: "%.2f", Date().timeIntervalSince(e))) s since; \(load)"
        }
        return "expanded \(after) s after the hover task started; \(load)"
    }

    /// The title expanded no sooner than the hover's 450 ms: a pass of the pointer doesn't reflow.
    private func assertWaitedTheHover(_ name: String) {
        guard let s = SidebarProbe.hoverStarted, let e = SidebarProbe.expandedAt else { return }
        XCTAssertGreaterThanOrEqual(e.timeIntervalSince(s), 0.44, "\(name): \(hoverState), before the hover's 450 ms")
    }

    /// The badge is still in the row after the hover's 450 ms have passed and the title has
    /// expanded. Before the fix (`if let git, !expandTitle`) the badge dropped from the layout
    /// the moment the title expanded: `expandedBodies` incremented with no badge body behind it.
    /// The badge is counted in the expanded bodies themselves, not against a count taken "before
    /// the expand": on a loaded Mac the main loop can stall past 450 ms inside the first 0.1 s,
    /// so that snapshot already held the expanded body and nothing came after it (2 vs 2).
    func testBadgeStaysInTheRowWhileHovered() throws {
        _ = show(hoveredRow(stage()))
        XCTAssertTrue(waitForExpand(), "the row never expanded its title (\(hoverState)), so this test proved nothing")
        assertWaitedTheHover("hovered row")
        XCTAssertEqual(SidebarProbe.expandedBadgeBodies, SidebarProbe.expandedBodies,
                       "the badge left the row when the title expanded under the pointer")
    }

    /// The hover, frame by frame: a row at rest, the pointer arriving (before the 450 ms
    /// expand), and after it. The badge must be present in all three and the row must not
    /// change width — into sidebar-hover-{rest,300ms,600ms}.png, for review beside the
    /// sidebar-git shots. The title is long enough to truncate, so the frames show the
    /// trade the fix makes: on hover the title gives up a little width to the badge, and
    /// the badge keeps its place. Each frame is its own test method: one shared method's
    /// three renders converged to the hovered state in all three files.
    func testRowAtRest() throws {
        let host = show(hoveredRow(longStage(), hovering: false))
        pump(0.2)
        XCTAssertNil(SidebarProbe.hoverStarted, "a row at rest started the hover's wait")
        XCTAssertEqual(SidebarProbe.expandedBodies, 0, "rest rendered the wrong hover state (expanded)")
        try snapshot(host, "rest")
    }

    func testRowHoveredBeforeExpand() throws {
        let host = show(hoveredRow(longStage()))
        pump(0.3)
        if SidebarProbe.expandedBodies > 0 {
            // The frame is "before the expand" only if it was taken before the 450 ms ran out. A
            // main loop stalled past them (a loaded Mac) can't show that state; one that
            // expanded sooner is the bug.
            assertWaitedTheHover("300ms")
            if let s = SidebarProbe.hoverStarted, Date().timeIntervalSince(s) >= 0.45 {
                throw XCTSkip("the main loop stalled past the hover's 450 ms before the 300 ms frame (\(hoverState)): the pre-expand state can't be caught")
            }
            XCTFail("300ms rendered the wrong hover state (\(hoverState))")
        }
        try snapshot(host, "300ms")
    }

    func testRowHoveredAfterExpand() throws {
        let host = show(hoveredRow(longStage()))
        XCTAssertTrue(waitForExpand(), "600ms rendered the wrong hover state (\(hoverState))")
        assertWaitedTheHover("600ms")
        try snapshot(host, "600ms")
    }

    private func longStage() -> SessionInfo {
        stage(title: "sidebar hover badge stays visible while the pointer rests on the row")
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        XCTAssertGreaterThan(SidebarProbe.badgeBodies, 0, "\(name) lost the badge")
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appending(path: "sidebar-hover-\(name).png"))
        XCTAssertGreaterThan(try Data(contentsOf: out.appending(path: "sidebar-hover-\(name).png")).count, 4_000,
                             "\(name) looks blank")
    }
}

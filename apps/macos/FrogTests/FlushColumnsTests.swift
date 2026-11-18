import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The sidebar and the inspector are flush, full-height columns (docs/design/flush): each
/// touches the window's edge, top to bottom, with no margin, corner radius or shadow, and a 1 pt
/// `Tokens.line` hairline on its inner edge. Folded, the inspector leaves nothing behind (the
/// "+N −M" pill is gone; the composer's status line carries the counts).
///
/// Read off the window as drawn: the real `WorkspaceView` in a titled, full-size-content window
/// (so it has a title bar's safe area to run up under), laid out and drawn offscreen and never
/// ordered in, sampled in dark, where the page is #000, the columns #0a0a0a and the line #2a2a2a.
@MainActor
final class FlushColumnsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/demo")
    private let size = CGSize(width: 1500, height: 900)

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
        // This Mac's real sessions don't belong in a test's window.
        Library.shared.stage(sessions: [])
    }

    override func tearDown() {
        Library.shared.unstage()
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A conversation with a changed file, so the inspector (and, before, its pill) has
    /// something to show.
    static func conversationWithChanges(_ folder: URL) throws -> Conversation {
        struct Record: Decodable {
            let type: String
            let env: Envelope?
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/fix-python-test.jsonl")
        let c = Conversation(preview: folder)
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONDecoder.frog.decode(Record.self, from: Data($0.utf8)).env }
            .forEach(c.ingest)
        return c
    }

    private struct Shot {
        let rep: NSBitmapImageRep
        let size: CGSize
        var controls: [CGRect] = []

        /// The sRGB color at a point (from the top-left), 0–255.
        func rgb(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let s = CGFloat(rep.pixelsWide) / size.width
            let px = min(rep.pixelsWide - 1, max(0, Int(x * s)))
            let py = min(rep.pixelsHigh - 1, max(0, Int(y * s)))
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return [-1, -1, -1] }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }

        /// A gray's level, 0–255 (the brightest channel where there's colour).
        func gray(_ x: CGFloat, _ y: CGFloat) -> Int { rgb(x, y).max() ?? 0 }

        /// Pixels in a rect (points) with any colour to them, at full resolution.
        func colored(in r: CGRect) -> Int {
            let s = CGFloat(rep.pixelsWide) / size.width
            var n = 0
            for py in max(0, Int(r.minY * s))..<min(rep.pixelsHigh, Int(r.maxY * s)) {
                for px in max(0, Int(r.minX * s))..<min(rep.pixelsWide, Int(r.maxX * s)) {
                    guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                    let v = [c.redComponent, c.greenComponent, c.blueComponent]
                    if (v.max()! - v.min()!) > 0.12 { n += 1 }
                }
            }
            return n
        }
    }

    /// Dark: the page, the columns' fill and the hairline.
    private let canvas = 0, column = 10, line = 42

    private func assertGray(_ shot: Shot, _ x: CGFloat, _ y: CGFloat, _ want: Int, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let got = shot.rgb(x, y)
        // The line comes out some steps off its token through the display's colour space (#2a2a2a
        // reads 49 here, 56 on CI's virtual display): it's a line if it's a gray well clear of
        // both the page (0) and the columns (10).
        let ok = want == self.line
            ? got.allSatisfy { (30...72).contains($0) } && Set(got).count == 1
            : got.allSatisfy { abs($0 - want) <= 3 }
        XCTAssertTrue(ok, "\(what) at (\(x), \(y)): \(got), want \(want)", file: file, line: line)
    }

    private func shoot(_ setup: (Panes) throws -> Void, width: CGFloat? = nil, sessionsOpen: Bool = true,
                       name: String = #function) throws -> (Shot, Panes) {
        let panes = Panes(Workspace(folder: folder, fresh: true))
        try setup(panes)
        let size = CGSize(width: width ?? self.size.width, height: self.size.height)
        let host = NSHostingView(rootView: WorkspaceView(panes: panes, sessionsOpen: sessionsOpen).frame(minWidth: 720, minHeight: 480))
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        // Never ordered in: see `PaneCardRenderTests`. `cacheDisplay` draws it all the same.
        pump(1.0)
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Controls, by the focus rings SwiftUI keeps for them (glass or not), in points from the
        // top-left.
        var controls: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRingView") {
                let r = v.convert(v.bounds, to: host)
                controls.append(host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height))
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        if let dir = ProcessInfo.processInfo.environment["FROG_FLUSH_DEBUG"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        w.close()
        return (Shot(rep: rep, size: host.bounds.size, controls: controls), panes)
    }

    private func showConversation(_ panes: Panes, inspector: Bool) throws {
        let c = try Self.conversationWithChanges(folder)
        panes.focused.workspace.testShow(c)
        panes.focused.showChanges = inspector
        panes.focus(panes.focused)
    }

    /// The docked sidebar starts at x = 0 and spans the window's height, from under the title
    /// bar to the bottom edge, square-cornered, with its hairline on the trailing edge.
    func testDockedSidebarIsFlushAndFullHeight() throws {
        let (shot, panes) = try shoot { try showConversation($0, inspector: false) }
        defer { panes.stopAll() }
        let w = WorkspaceView.sessionsWidth
        let h = shot.size.height
        // The corners: a radius, or an inset, leaves the page there.
        assertGray(shot, 0.5, 0.5, column, "the sidebar's top-left corner")
        assertGray(shot, 0.5, h - 0.5, column, "the sidebar's bottom-left corner")
        assertGray(shot, w - 3, 0.5, column, "the sidebar's top-right corner, under the title bar")
        assertGray(shot, w - 3, h - 0.5, column, "the sidebar's bottom-right corner")
        // Its leading edge, all the way down.
        for y in stride(from: CGFloat(1), to: h - 1, by: 37) { assertGray(shot, 0.5, y, column, "the sidebar's leading edge") }
        // The hairline on its inner edge, top to bottom, then the page.
        for y: CGFloat in [1, h / 2, h - 1] {
            assertGray(shot, w - 0.5, y, line, "the sidebar's hairline")
            assertGray(shot, w + 2, y, canvas, "the page just past the sidebar's hairline")
        }
    }

    /// The docked inspector's trailing edge is the window's, top to bottom, square-cornered,
    /// with its hairline on the leading edge.
    func testDockedInspectorIsFlushAndFullHeight() throws {
        let (shot, panes) = try shoot { try showConversation($0, inspector: true) }
        defer { panes.stopAll() }
        let pane = panes.items[0]
        let W = shot.size.width, h = shot.size.height
        let edge = W - pane.cardWidth
        XCTAssertTrue(pane.showChanges)
        assertGray(shot, W - 0.5, 0.5, column, "the inspector's top-right corner")
        assertGray(shot, W - 0.5, h - 0.5, column, "the inspector's bottom-right corner")
        assertGray(shot, edge + 3, 0.5, column, "the inspector's top-left corner, under the title bar")
        assertGray(shot, edge + 3, h - 0.5, column, "the inspector's bottom-left corner")
        // Down its trailing edge, where nothing of its content reaches (the file rows' fills do,
        // near the top).
        for y in stride(from: CGFloat(1), to: 40, by: 6) { assertGray(shot, W - 0.5, y, column, "the inspector's trailing edge") }
        for y in stride(from: CGFloat(500), to: h - 1, by: 37) { assertGray(shot, W - 0.5, y, column, "the inspector's trailing edge") }
        for y: CGFloat in [1, h / 2, h - 1] {
            assertGray(shot, edge + 0.5, y, line, "the inspector's hairline")
            assertGray(shot, edge - 2, y, canvas, "the page just before the inspector's hairline")
        }
    }

    /// Folded, the inspector is gone: no pill, no card, nothing at the trailing edge but the
    /// page (and the timeline rail, at the transcript's edge).
    func testFoldedInspectorLeavesNothing() throws {
        let (shot, panes) = try shoot { try showConversation($0, inspector: false) }
        defer { panes.stopAll() }
        // The pill's glass doesn't draw offscreen, but its green "+N" and red "−M" do: nothing in
        // the window's top-right corner may have colour.
        let colored = shot.colored(in: CGRect(x: shot.size.width - 220, y: 0, width: 220, height: 140))
        XCTAssertEqual(colored, 0, "coloured pixels in the top-right corner: the pill is still there")
        // Glass doesn't draw offscreen, so the pill's button is found by its focus ring.
        let corner = CGRect(x: shot.size.width - 220, y: 0, width: 220, height: 140)
        XCTAssertEqual(shot.controls.filter { $0.intersects(corner) }, [], "a control in the top-right corner: the pill is still there")
        XCTAssertTrue(panes.items[0].hasTabs, "the conversation has changes, so the pill would have shown")
        let W = shot.size.width
        // Where the pill stood (its top-right corner, under the title bar's row) and down the
        // window's trailing edge.
        for x in stride(from: W - 150, through: W - 60, by: 6) {
            for y in stride(from: CGFloat(1), through: 80, by: 6) {
                assertGray(shot, x, y, canvas, "the folded inspector's corner")
            }
        }
        for y in stride(from: CGFloat(1), to: shot.size.height - 1, by: 23) {
            assertGray(shot, W - 0.5, y, canvas, "the window's trailing edge with the inspector folded")
        }
    }

    /// Collapsed, the sidebar is gone: nothing at the window's left edge but the page, top to
    /// bottom, and the panes start at x = 0. (Before, a 52 pt rail stood there.)
    func testCollapsedSidebarLeavesNothing() throws {
        let (shot, panes) = try shoot({ try showConversation($0, inspector: false) }, sessionsOpen: false)
        defer { panes.stopAll() }
        let h = shot.size.height
        for x: CGFloat in [0.5, 26, 51] {
            for y in stride(from: CGFloat(1), to: h - 1, by: 29) {
                assertGray(shot, x, y, canvas, "the window's left edge with the sidebar collapsed")
            }
        }
    }

    /// The collapsed sidebar's toggle carries a dot only while a conversation waits on you, and
    /// lists the live ones waiting first.
    func testToggleShowsWhatNeedsYou() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func s(_ id: String, ago: Int64) -> SessionInfo {
            SessionInfo(id: id, modified: now - ago, created: now - ago - 1, model: "m", firstInput: nil, title: id,
                        end: nil, forkedFrom: nil, cwd: "/tmp/demo")
        }
        let sessions = [s("a", ago: 10), s("b", ago: 20), s("c", ago: 30), s("d", ago: 40)]
        let toggle = SidebarToggle(toggle: {}, open: { _ in })
        Library.shared.stage(sessions: sessions, live: ["a": .running, "b": .unread])
        XCTAssertFalse(toggle.needsYou, "running and unread don't need you")
        Library.shared.stage(sessions: sessions, live: ["a": .running, "b": .unread, "c": .waiting, "d": .running])
        XCTAssertTrue(toggle.needsYou)
        XCTAssertEqual(toggle.live.map(\.session.id), ["c", "a", "d", "b"], "waiting, then running (newest first), then unread")
    }

    // MARK: Split panes: no header pills, inspectors on the sidebar's first row

    /// Two panes, both showing a conversation with changes, pane 1 focused. Wide enough (drawn
    /// offscreen, so no screen clamps it) for both inspectors to dock beside the sidebar.
    private func splitShot(inspectors: Bool, width: CGFloat = 2600, name: String = #function) throws -> (Shot, Panes) {
        try shoot({ panes in
            try showConversation(panes, inspector: inspectors)
            panes.split(nil, on: .right, window: nil)
            panes.items[1].workspace.testShow(try Self.conversationWithChanges(folder))
            panes.items[1].showChanges = inspectors
            panes.focus(panes.items[0])
        }, width: width, name: name)
    }

    /// The boundary between the two panes: they share what's right of the docked sidebar evenly.
    private func middle(_ shot: Shot) -> CGFloat {
        WorkspaceView.sessionsWidth + (shot.size.width - WorkspaceView.sessionsWidth) / 2
    }

    /// A row of controls' vertical centre: the topmost control in an x range (by its focus ring).
    private func firstRow(_ shot: Shot, from x0: CGFloat, to x1: CGFloat) -> CGFloat? {
        shot.controls.filter { $0.minX >= x0 - 0.5 && $0.maxX <= x1 + 0.5 && $0.height < 60 }
            .min { $0.minY < $1.minY }?.midY
    }

    /// Split, no pane has a header: no control at the top of either transcript, where the
    /// number, state and model pill stood.
    func testSplitPanesHaveNoHeaderPill() throws {
        let (shot, panes) = try splitShot(inspectors: false)
        defer { panes.stopAll() }
        XCTAssertTrue(panes.isSplit)
        let mid = middle(shot), W = shot.size.width
        let tops = [CGRect(x: WorkspaceView.sessionsWidth + 1, y: 0, width: mid - WorkspaceView.sessionsWidth - 60, height: 100),
                    CGRect(x: mid + 1, y: 0, width: W - mid - 60, height: 100)]
        let pills = shot.controls.filter { c in tops.contains { $0.intersects(c) } }
        XCTAssertEqual(pills, [], "controls at the top of a split pane: its header pill is still there")
    }

    /// Every inspector's tab strip, split or not, sits on one line with the sidebar's first row
    /// (New session), right under the title bar.
    func testInspectorStripsShareTheSidebarsFirstRow() throws {
        let (single, one) = try shoot { try showConversation($0, inspector: true) }
        defer { one.stopAll() }
        let card = one.items[0].cardWidth
        let sidebar = try XCTUnwrap(firstRow(single, from: 0, to: WorkspaceView.sessionsWidth), "the sidebar's first row")
        let alone = try XCTUnwrap(firstRow(single, from: single.size.width - card, to: single.size.width), "the inspector's strip")
        XCTAssertEqual(alone, sidebar, accuracy: 1, "unsplit: the inspector's strip and the sidebar's first row")

        let (split, two) = try splitShot(inspectors: true)
        defer { two.stopAll() }
        XCTAssertTrue(two.items.allSatisfy { $0.showChanges })
        let mid = middle(split), W = split.size.width
        let left = try XCTUnwrap(firstRow(split, from: mid - card, to: mid), "pane 1's inspector strip")
        let right = try XCTUnwrap(firstRow(split, from: W - card, to: W), "pane 2's inspector strip")
        let splitSidebar = try XCTUnwrap(firstRow(split, from: 0, to: WorkspaceView.sessionsWidth))
        XCTAssertEqual(left, sidebar, accuracy: 1, "split: pane 1's strip and the sidebar's first row")
        XCTAssertEqual(right, sidebar, accuracy: 1, "split: pane 2's strip and the sidebar's first row")
        XCTAssertEqual(splitSidebar, sidebar, accuracy: 1, "the sidebar's first row doesn't move when split")
    }

    /// With no header to tint, the focused pane still reads as the focused one: the other
    /// pane's composer steps back (its placeholder and stroke dimmer).
    func testFocusedPaneStillStandsOut() throws {
        let (shot, panes) = try splitShot(inspectors: false)
        defer { panes.stopAll() }
        XCTAssertTrue(panes.focused === panes.items[0])
        let mid = middle(shot), W = shot.size.width, h = shot.size.height
        func brightest(_ r: CGRect) -> Int {
            var m = 0
            for y in stride(from: r.minY, to: r.maxY, by: 1) {
                for x in stride(from: r.minX, to: r.maxX, by: 2) { m = max(m, shot.gray(x, y)) }
            }
            return m
        }
        // The composers: the bottom 150 pt of each pane's column.
        let focused = brightest(CGRect(x: WorkspaceView.sessionsWidth + 40, y: h - 150, width: mid - WorkspaceView.sessionsWidth - 120, height: 145))
        let other = brightest(CGRect(x: mid + 40, y: h - 150, width: W - mid - 120, height: 145))
        XCTAssertGreaterThan(focused - other, 30, "the focused pane's composer (\(focused)) should stand out from the other's (\(other))")
    }
}

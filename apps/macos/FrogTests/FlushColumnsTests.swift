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
        // The line comes out a few steps off its token through the window's colour space (49
        // for #2a2a2a); it's still far from the page (0) and the columns (10).
        let slack = want == self.line ? 9 : 3
        let ok = got.allSatisfy { abs($0 - want) <= slack }
        XCTAssertTrue(ok, "\(what) at (\(x), \(y)): \(got), want \(want)", file: file, line: line)
    }

    private func shoot(_ setup: (Panes) throws -> Void, width: CGFloat? = nil, name: String = #function) throws -> (Shot, Panes) {
        let panes = Panes(Workspace(folder: folder, fresh: true))
        try setup(panes)
        let size = CGSize(width: width ?? self.size.width, height: self.size.height)
        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(minWidth: 720, minHeight: 480))
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
}

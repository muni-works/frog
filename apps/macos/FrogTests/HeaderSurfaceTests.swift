import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The title row is an opaque surface in every mode (docs/design/chrome/spec.md, 3): a page
/// scrolled down runs beneath it, never through the crumbs and the window controls. Found in
/// Cam's click-through (2026-11-19): Skills scrolled, its rows ran through its crumbs ("Settings ›
/// Skills" now), the figure and the capsule.
///
/// The real `WorkspaceView` with its toolbar bridged into a titled, unified window, ordered in
/// hidden (`orderInForTest`), as `FlushSnapshotTests` does; every scroll view is scrolled to its
/// end, and the title row's empty middle (between the crumbs and the controls) must be canvas.
/// Settings › Shortcuts is long in any test host; Settings › Skills is made long with the
/// agent pages' fixture (CustomizeModeTests) so a moved page is checked too.
@MainActor
final class HeaderSurfaceTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/demo")

    override func setUpWithError() throws {
        try XCTSkipIf(TestRunner.isCI, "display-driven: orders a real window in; run locally")
    }

    private func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Pixels in the title row's middle that aren't the canvas, with the page scrolled to its end.
    private func inkInTitleRow(name: String = #function, _ setup: (Panes) -> Void) throws -> Int {
        let panes = Panes(Workspace(folder: folder, fresh: true))
        defer { panes.stopAll() }
        setup(panes)
        let host = NSHostingView(rootView: WorkspaceView(panes: panes).font(.frog(size: 13)).frame(minWidth: 720, minHeight: 480))
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1280, height: 640),
                         styleMask: [.titled, .resizable, .fullSizeContentView, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.toolbarStyle = .unified
        w.contentView = host
        w.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        w.orderInForTest()
        defer { w.close() }
        pump(1.5)
        // Every scroll view to its end: the page's content now stands under the title row.
        func scroll(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView, doc.bounds.height > s.contentView.bounds.height {
                let end = doc.isFlipped ? doc.bounds.height - s.contentView.bounds.height : 0
                s.contentView.scroll(to: CGPoint(x: 0, y: end))
                s.reflectScrolledClipView(s.contentView)
            }
            v.subviews.forEach(scroll)
        }
        scroll(host)
        pump(0.8)
        let frame = try XCTUnwrap(host.superview)
        frame.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // TEST_RUNNER_FROG_HEADER_DEBUG=<dir>: the picture, to look at.
        if let dir = ProcessInfo.processInfo.environment["FROG_HEADER_DEBUG"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
        let top = host.safeAreaInsets.top
        // Between the crumbs ("Settings › Shortcuts" ends 150 past the sidebar) and the controls.
        let x0 = Int((WorkspaceView.sessionsWidth + 160) * scale), x1 = Int((frame.bounds.width - 250) * scale)
        let y0 = Int(4 * scale), y1 = Int((top - 4) * scale)
        var ink = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.16 { ink += 1 }
            }
        }
        return ink
    }

    func testSettingsScrolledStaysUnderTheTitleRow() throws {
        let ink = try inkInTitleRow { $0.showSettings("shortcuts") }
        XCTAssertEqual(ink, 0, "Settings scrolled: the page shows through the title row")
    }

    /// An agent section (once its own mode) under the same band: Skills with the fixture's skills,
    /// scrolled to its end.
    func testSkillsScrolledStaysUnderTheTitleRow() throws {
        CustomizeStore.loads = false
        defer { CustomizeStore.loads = true }
        let ink = try inkInTitleRow { panes in
            panes.showSettings("skills")
            CustomizeModeTests.stageFixture(panes.customize)
        }
        XCTAssertEqual(ink, 0, "Settings › Skills scrolled: the page shows through the title row")
    }
}

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Frog

/// The freeze of 2026-11-16 (Frog 0.5.0, macOS 27.0.1): the main thread spun forever in
/// SwiftUI's focus walk, `FocusNavigationSequence.next()`, reached from a layout pass that hid a
/// view (`-[NSView _setHidden:]` → `nextValidKeyView` → `_recursiveGatherAllKeyViewCandidates`).
/// On macOS 27 that walk never ends while the inspector card is Liquid Glass (`.glassEffect`)
/// inside the pane's `GlassEffectContainer`, holding views that take the keyboard (the terminal,
/// the preview's web view, its buttons). Anything that walks the key view loop then hangs:
/// ordering the window in, AppKit recalculating the loop, or hiding the view that has focus.
///
/// Each test fails by name on a hang: the allowance is a minute, and `scripts/test.sh` runs
/// with per-test timeouts.
@MainActor
final class FocusHideFreezeTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/demo")

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Rig {
        let panes: Panes
        let conversation: Conversation
        let window: NSWindow
        let host: NSView
    }

    /// The window as the app builds it, on screen: one pane showing a conversation, the session
    /// list and the inspector docked, a terminal (with a screen, so its grid is up) and a preview
    /// open. `cardAtOrderIn: false` brings the card up after the window is on screen.
    private func rig(cardAtOrderIn: Bool, preview: Bool = false) -> Rig {
        let panes = Panes(Workspace(folder: folder, fresh: true))
        let c = Conversation(folder: folder, link: nil, replay: false, session: "demo")
        panes.focused.workspace.testShow(c)
        panes.focused.showChanges = cardAtOrderIn
        c.panes.openTerminal(cwd: folder)
        _ = c.panes.apply(.paneOpened(id: "t1", kind: .terminal, title: "zsh", cwd: folder.path, url: nil))
        _ = c.panes.apply(.paneScreen(PaneScreen(id: "t1", cols: 80, rows: 24, lines: ["$ "], cursor: [0, 2], seq: 1)))
        c.panes.openPreview()
        _ = c.panes.apply(.paneOpened(id: "p1", kind: .preview, title: "Demo", cwd: nil,
                                      url: "data:text/html,<input autofocus><p>preview</p>"))
        c.panes.selected = .pane(preview ? "p1" : "t1")
        panes.focus(panes.focused)

        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(minWidth: 720, minHeight: 480))
        let w = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1500, height: 900),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        pump(1.0)
        panes.focused.showChanges = true
        pump(1.0)
        return Rig(panes: panes, conversation: c, window: w, host: host)
    }

    private func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    private func close(_ r: Rig) {
        r.panes.stopAll()
        r.window.close()
    }

    /// The window opening with the inspector up (a restored window, or #384's render test).
    func testOrderInWithInspector() throws {
        let r = rig(cardAtOrderIn: true)
        defer { close(r) }
        XCTAssertNotNil(find(TerminalGridView.self, in: r.host), "the inspector's terminal should be up")
    }

    /// AppKit rebuilding the key view loop with the inspector up.
    func testRecalculateKeyViewLoopWithInspector() {
        let r = rig(cardAtOrderIn: false)
        defer { close(r) }
        r.window.recalculateKeyViewLoop()
        pump(0.5)
    }

    /// The freeze's own entry: the terminal has the keyboard and gets hidden, so AppKit asks for
    /// the next valid key view.
    func testHideFocusedTerminal() throws {
        let r = rig(cardAtOrderIn: false)
        defer { close(r) }
        let grid = try XCTUnwrap(find(TerminalGridView.self, in: r.host), "no terminal grid")
        XCTAssertTrue(r.window.makeFirstResponder(grid))
        grid.isHidden = true
        pump(0.5)
        XCTAssertFalse(r.window.firstResponder === grid, "focus stayed on a hidden terminal")
    }

    /// The same with the preview's web view holding the keyboard.
    func testHideFocusedPreview() throws {
        let r = rig(cardAtOrderIn: false, preview: true)
        defer { close(r) }
        pump(1.0)
        let web = try XCTUnwrap(find(WKWebView.self, in: r.host), "no web view")
        XCTAssertTrue(r.window.makeFirstResponder(web))
        web.isHidden = true
        pump(0.5)
    }

    /// The window narrowing (a drag on its edge, in steps) through the width where the inspector
    /// can't stay docked, with the terminal holding the keyboard.
    func testNarrowUndocksInspectorWithTerminalFocused() throws {
        let r = rig(cardAtOrderIn: false)
        defer { close(r) }
        let grid = try XCTUnwrap(find(TerminalGridView.self, in: r.host), "no terminal grid")
        XCTAssertTrue(r.window.makeFirstResponder(grid))
        var f = r.window.frame
        while f.width > 1000 {
            f.size.width = max(1000, f.width - 20)
            r.window.setFrame(f, display: true)
            pump(0.016)
        }
        pump(1.0)
        XCTAssertFalse(r.window.firstResponder === grid, "focus stayed on a terminal that left the window")
    }

    /// Switching the inspector to Changes with the terminal focused: the terminal stays mounted
    /// behind it, at opacity 0, which hides its view.
    func testTabAwayFromFocusedTerminal() throws {
        let r = rig(cardAtOrderIn: false)
        defer { close(r) }
        let grid = try XCTUnwrap(find(TerminalGridView.self, in: r.host), "no terminal grid")
        XCTAssertTrue(r.window.makeFirstResponder(grid))
        r.conversation.panes.selected = .changes
        pump(1.0)
    }
}

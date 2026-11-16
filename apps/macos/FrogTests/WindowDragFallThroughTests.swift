import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// A drag meant for the inspector's resize grip or a pane divider must land on it. The window
/// root drags the window from any empty space (`WindowDragGesture`, `RootView`), so a press that
/// misses a control by a few points moves the window instead. These send mouse events through
/// the app (with the root built as `RootView` builds it) and check the control took the drag.
///
/// They can't see the window drag itself: a synthetic drag on empty canvas doesn't start one in a
/// test (checked across a grid of points), so "the window didn't move" isn't asserted.
@MainActor
final class WindowDragFallThroughTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/demo")

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func rig(split: Bool = false) -> (Panes, NSWindow) {
        let panes = Panes(Workspace(folder: folder, fresh: true))
        let c = Conversation(folder: folder, link: nil, replay: false, session: "demo")
        panes.focused.workspace.testShow(c)
        if split { panes.split(nil, on: .right, window: nil) }
        panes.focus(panes.items[0])
        let root = WorkspaceView(panes: panes)
            .frame(minWidth: 720, minHeight: 480)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1500, height: 900),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        // On screen for AppKit (ordered in, so it builds a key view loop) but never seen: far
        // off the desktop, transparent, not key, and the app isn't activated.
        w.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        w.alphaValue = 0
        w.orderFrontRegardless()
        pump(1.0)
        panes.items[0].showChanges = true
        pump(1.0)
        return (panes, w)
    }

    /// A press, a drag of `dx` in steps, and a release, at `top` (points from the top-left).
    private func drag(_ w: NSWindow, from top: CGPoint, by dx: CGFloat = -60) {
        let h = w.contentView!.bounds.height
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: h - top.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.sendEvent(event(.leftMouseDown, top.x))
        pump(0.05)
        for i in 1...6 {
            NSApp.sendEvent(event(.leftMouseDragged, top.x + dx * CGFloat(i) / 6))
            pump(0.03)
        }
        NSApp.sendEvent(event(.leftMouseUp, top.x + dx))
        pump(0.3)
    }

    /// Drags the grip `offset` points right of the card's leading edge; returns (before, after).
    private func dragGrip(at offset: CGFloat) -> (CGFloat, CGFloat) {
        let (panes, w) = rig()
        defer { panes.stopAll(); w.close() }
        // The test host shares the app's defaults: put the saved width back.
        let saved = UserDefaults.standard.object(forKey: PaneArea.widthKey)
        defer { UserDefaults.standard.set(saved, forKey: PaneArea.widthKey) }
        let pane = panes.items[0]
        let before = pane.cardWidth
        let edge = w.contentView!.bounds.width - WorkspaceView.margin - before
        drag(w, from: CGPoint(x: edge + offset, y: 300))
        return (before, pane.cardWidth)
    }

    func testGripTakesDragOnCardEdge() {
        let (before, after) = dragGrip(at: 4)
        XCTAssertGreaterThan(after, before, "dragging the grip left should widen the card")
    }

    /// A press just outside the card's edge is the grip's, not the canvas's (which drags the
    /// window).
    func testGripTakesDragJustOutsideCard() {
        let (before, after) = dragGrip(at: -5)
        XCTAssertGreaterThan(after, before, "a press 5 pt outside the card's edge should still resize it")
    }

    /// The divider between split panes takes its drag.
    func testPaneDividerTakesDrag() {
        let (panes, w) = rig(split: true)
        defer { panes.stopAll(); w.close() }
        XCTAssertEqual(panes.items.count, 2)
        let before = panes.layout
        // Two equal panes right of the docked session list.
        let ext = WorkspaceView.margin + WorkspaceView.sessionsWidth + WorkspaceView.gap
        drag(w, from: CGPoint(x: ext + (w.contentView!.bounds.width - ext) / 2, y: 450))
        XCTAssertNotEqual(panes.layout, before, "dragging the divider should resize the panes")
    }
}

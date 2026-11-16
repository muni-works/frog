import AppKit
import XCTest
@testable import Frog

/// The test run stays in the background: tests run while someone works at this Mac (agents
/// build and test on it all day), so a test never shows a window, activates the app or takes
/// the keyboard. The host already runs as an accessory app with no windows of its own
/// (`FrogApp.init` under `SingleInstance.isTesting`); a test that needs a real window orders
/// it in with `orderInForTest()`, and `BackgroundGuard` fails any test that shows one anyway.
extension NSWindow {
    /// Orders the window in, so it lays out, draws, keeps its screen and gets display frames
    /// like any window, without anyone seeing it: fully transparent, click-through, out of
    /// window cycling and Mission Control, no open/close animation, and never made key (the
    /// app stays inactive, so the keyboard stays wherever the user has it). Snapshots don't
    /// mind: `cacheDisplay` draws the view itself, not the window's composited pixels.
    func orderInForTest() {
        alphaValue = 0
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior.formUnion([.transient, .ignoresCycle])
        orderFront(nil)
    }

    /// A window up its parent chain was ordered in with `orderInForTest()`.
    var hasHiddenAncestor: Bool {
        var p = parent
        while let w = p {
            if w.alphaValue <= 0.01 { return true }
            p = w.parent
        }
        return false
    }

    /// Someone at the Mac could see this window, by the window server's account (what's on
    /// the display, which a popover's own fade-in can disagree with `alphaValue` about).
    var isSeenByUser: Bool {
        guard isVisible, windowNumber > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]])?.first
        else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool ?? false) && (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.01
    }
}

/// Windows the app hangs off a test's hidden window are hidden from the start too: a panel
/// (the git card) added as its child, and a popover (a picker) shown from a view in it. Done
/// before they reach the screen, not after: a popover fades itself in on the window server,
/// past any `alphaValue` set once it's up, so it goes without the animation.
enum HideChildren {
    static func install() {
        swap(NSWindow.self, #selector(NSWindow.addChildWindow(_:ordered:)), #selector(NSWindow.frogTest_addChildWindow(_:ordered:)))
        swap(NSPopover.self, #selector(NSPopover.show(relativeTo:of:preferredEdge:)), #selector(NSPopover.frogTest_show(relativeTo:of:preferredEdge:)))
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let m = class_getInstanceMethod(cls, a), let n = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(m, n)
    }
}

extension NSWindow {
    @objc fileprivate func frogTest_addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        if alphaValue <= 0.01 || hasHiddenAncestor {
            child.alphaValue = 0
            child.ignoresMouseEvents = true
        }
        frogTest_addChildWindow(child, ordered: place)  // the original, after the swap
    }
}

extension NSPopover {
    @objc fileprivate func frogTest_show(relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        let hidden = view.window.map { $0.alphaValue <= 0.01 || $0.hasHiddenAncestor } ?? false
        if hidden { animates = false }
        frogTest_show(relativeTo: rect, of: view, preferredEdge: edge)  // the original
        if hidden, let w = contentViewController?.view.window {
            w.alphaValue = 0
            w.ignoresMouseEvents = true
        }
    }
}

/// Fails the test that put a window in front of the user or activated the app, by name, so a
/// new test can't quietly bring back the screen-grabbing run. Installed once per test process
/// by the bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass` in project.yml).
@objc(FrogTestsBackgroundGuard)
@MainActor
final class BackgroundGuard: NSObject, @preconcurrency XCTestObservation {
    /// The test running now. An issue is recorded the moment it's seen, while the test still
    /// runs: XCTest throws on an issue recorded after the test has finished.
    private var current: XCTestCase?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        HideChildren.install()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func testCaseWillStart(_ testCase: XCTestCase) { current = testCase }
    func testCaseDidFinish(_ testCase: XCTestCase) { current = nil }

    @objc private func becameActive(_ note: Notification) {
        fail("the test host became the active app (it took the keyboard and menu bar)")
    }

    @objc private func windowChanged(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        if w.isSeenByUser {
            fail("a window (\(type(of: w)), \(Int(w.frame.width))×\(Int(w.frame.height))) was on screen where the user can see it: order it in with orderInForTest(), not orderFront")
        }
        if w.isKeyWindow, NSApp.isActive {
            fail("a window became key while the host was active (it took the keyboard)")
        }
    }

    private func fail(_ what: String) {
        let message = "Test run left the background: \(what)"
        guard let current else { return print(message) }
        current.record(XCTIssue(type: .assertionFailure, compactDescription: message))
    }
}

/// The host's home is its own empty folder, not the user's (`TestHome.isolate`, run first in `FrogApp.init`).
final class TestHomeTests: XCTestCase {
    func testHostHasItsOwnHome() {
        XCTAssertTrue(NSHomeDirectory().contains("frog-test-home-"), NSHomeDirectory())
        XCTAssertTrue(URL.homeDirectory.path.contains("frog-test-home-"), URL.homeDirectory.path)
        XCTAssertTrue(FrogPaths.sessions.path.hasPrefix(NSHomeDirectory()), FrogPaths.sessions.path)
        XCTAssertEqual(ProcessInfo.processInfo.environment["HOME"], NSHomeDirectory(), "child processes get it too")
    }

    /// No Dock icon, no menu bar, not frontmost (`FrogApp.init` under `SingleInstance.isTesting`).
    @MainActor func testHostIsABackgroundApp() {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(NSApp.isActive)
    }
}

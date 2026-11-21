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
        swap(NSWindow.self, #selector(NSWindow.beginSheet(_:completionHandler:)), #selector(NSWindow.frogTest_beginSheet(_:completionHandler:)))
        swap(NSWindow.self, #selector(NSWindow.beginCriticalSheet(_:completionHandler:)), #selector(NSWindow.frogTest_beginCriticalSheet(_:completionHandler:)))
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

    /// A sheet (an alert, a confirmation dialog) on a hidden window is hidden too, before it
    /// slides down.
    @objc fileprivate func frogTest_beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        hideIfParentHidden(sheet)
        frogTest_beginSheet(sheet, completionHandler: completionHandler)  // the original
    }

    @objc fileprivate func frogTest_beginCriticalSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        hideIfParentHidden(sheet)
        frogTest_beginCriticalSheet(sheet, completionHandler: completionHandler)  // the original
    }

    private func hideIfParentHidden(_ sheet: NSWindow) {
        guard alphaValue <= 0.01 || hasHiddenAncestor else { return }
        sheet.alphaValue = 0
        sheet.ignoresMouseEvents = true
        sheet.animationBehavior = .none
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
        HiddenMenus.install()
        HiddenMenus.onEscape = { [weak self] what in self?.fail(what) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        current = testCase
        // A test that leaves a sidecar of this host's running fails, by name, and the sidecar is
        // stopped (it would hold its port for the rest of the run, as frog-apple held 8912).
        let before = Set(SidecarGuard.running().map(\.pid))
        testCase.addTeardownBlock { @MainActor in
            let left = SidecarGuard.running().filter { !before.contains($0.pid) }
            guard !left.isEmpty else { return }
            for s in left { kill(s.pid, SIGTERM) }
            XCTFail("Test left a sidecar running: \(left.map { "\(($0.path as NSString).lastPathComponent) (pid \($0.pid))" }.joined(separator: ", ")). Tests run with FROG_SIDECARS=off; a test that needs one sets FROG_SIDECARS=ephemeral and stops it.")
        }
    }
    func testCaseDidFinish(_ testCase: XCTestCase) {
        current = nil
        ReleaseClosedWindows.run()
    }

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

    fileprivate func fail(_ what: String) {
        let message = "Test run left the background: \(what)"
        guard let current else { return print(message) }
        current.record(XCTIssue(type: .assertionFailure, compactDescription: message))
    }
}

/// A test's window, once it's off screen, lets go of its SwiftUI. Tests close their windows with
/// `isReleasedWhenClosed = false`, and a closed window can stay alive (a view in it holds it):
/// its hosting view kept observing the shared stores, so every later test that staged sessions
/// re-rendered each leftover workspace's sidebar. By SidebarHoverBadgeTests, 110 classes in, ten
/// such windows built its row 74 to 218 times in a second and held the main actor long enough
/// that the row's 450 ms hover took 0.66 to 1.13 s (2026-11-21; alone: 1 to 3 bodies, 0.455 s).
/// Only plain `NSWindow`s a test made: the app's own scene windows and the system's are left be.
@MainActor
enum ReleaseClosedWindows {
    static func run() {
        for w in NSApp.windows where type(of: w) == NSWindow.self && !w.isVisible {
            guard let content = w.contentView, String(describing: type(of: content)).hasPrefix("NSHostingView") else { continue }
            w.contentView = nil
        }
    }
}

/// This test host's sidecars: `frog-apple` and `tang-llm` from its own bundle (engines start
/// them detached, so they aren't the host's children; the bundle path is what ties them to this
/// run, not another worktree's or the installed app's).
enum SidecarGuard {
    static let names = ["frog-apple", "tang-llm"]

    static func isOurs(path: String, bundle: String = Bundle.main.bundlePath) -> Bool {
        path.hasPrefix(bundle + "/") && names.contains((path as NSString).lastPathComponent)
    }

    static func running(bundle: String = Bundle.main.bundlePath) -> [(pid: pid_t, path: String)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(max(got, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            let path = String(cString: buf)
            return isOurs(path: path, bundle: bundle) ? (pid, path) : nil
        }
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

    /// Its defaults are its own too: nothing set in the debug app (the developer's verbosity,
    /// density, archived sessions) reaches a test, and nothing a test sets reaches the app.
    /// The probe keys are written to the app's real domain for the moment it takes, and
    /// removed.
    func testHostHasItsOwnDefaults() {
        let app = (Bundle.main.bundleIdentifier ?? "toys.frog.dev") as CFString
        let key = "frogTestHomeProbe-\(getpid())"
        defer {
            CFPreferencesSetAppValue(key as CFString, nil, app)
            CFPreferencesSetAppValue((key + "-test") as CFString, nil, app)
            CFPreferencesAppSynchronize(app)
            UserDefaults.standard.removeObject(forKey: key + "-test")
        }
        // Something the developer set in the app.
        CFPreferencesSetAppValue(key as CFString, "user" as CFString, app)
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "the test host read the app's own defaults")
        // Something a test sets.
        UserDefaults.standard.set("test", forKey: key + "-test")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key + "-test"), "test")
        XCTAssertNil(CFPreferencesCopyAppValue((key + "-test") as CFString, app), "a test wrote to the app's own defaults")
    }

    /// A normal launch never isolates, whatever its environment says: the switch is XCTest's
    /// injection library loaded in the process, which no installed Frog has.
    func testOnlyAnXCTestHostIsolates() {
        let inject = "/Applications/Frog.app/Contents/Frameworks/libXCTestBundleInject.dylib"
        let launched = ["/Applications/Frog.app/Contents/MacOS/Frog", "/usr/lib/libSystem.B.dylib"]
        let session = ["XCTestConfigurationFilePath": "", "XCTestSessionIdentifier": "3BF534B8"]
        // A normal launch.
        XCTAssertFalse(TestHome.shouldIsolate(environment: ["HOME": "/Users/x"], loadedImages: launched))
        // A shell that exports XCTest's variables, or a launch with them: still not a test host.
        XCTAssertFalse(TestHome.shouldIsolate(environment: session, loadedImages: launched))
        XCTAssertFalse(TestHome.shouldIsolate(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], loadedImages: launched))
        // The library without Xcode's session (loaded some other way): not either.
        XCTAssertFalse(TestHome.shouldIsolate(environment: [:], loadedImages: launched + [inject]))
        // A test host.
        XCTAssertTrue(TestHome.shouldIsolate(environment: session, loadedImages: launched + [inject]))
        // A test that reads this Mac's real state on purpose.
        XCTAssertFalse(TestHome.shouldIsolate(environment: session.merging(["FROG_LIVE_NODE": "mew"]) { $1 }, loadedImages: launched + [inject]))
    }

    /// Engines a test opens start no sidecar: their fixed ports are the real app's.
    func testHostStartsNoSidecars() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["FROG_SIDECARS"], "off")
        XCTAssertEqual(Frog.environment["FROG_SIDECARS"], "off", "engines get it too")
        XCTAssertTrue(SidecarGuard.running().isEmpty, "\(SidecarGuard.running())")
    }

    /// The guard knows this host's sidecars by their place in its bundle, and nobody else's.
    func testSidecarGuardMatchesOnlyThisHostsBundle() {
        let bundle = "/tmp/wt/build/Frog.app"
        XCTAssertTrue(SidecarGuard.isOurs(path: bundle + "/Contents/Resources/frog-apple", bundle: bundle))
        XCTAssertTrue(SidecarGuard.isOurs(path: bundle + "/Contents/Resources/tang-llm", bundle: bundle))
        XCTAssertFalse(SidecarGuard.isOurs(path: "/Applications/Frog.app/Contents/Resources/frog-apple", bundle: bundle))
        XCTAssertFalse(SidecarGuard.isOurs(path: bundle + "/Contents/Resources/frog", bundle: bundle))
        XCTAssertFalse(SidecarGuard.isOurs(path: "/tmp/wt/build/Frog.app2/Contents/Resources/frog-apple", bundle: bundle))
    }

    /// No Dock icon, no menu bar, not frontmost (`FrogApp.init` under `SingleInstance.isTesting`).
    @MainActor func testHostIsABackgroundApp() {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertFalse(NSApp.isActive)
    }
}

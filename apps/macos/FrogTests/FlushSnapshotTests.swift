import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The window with flush columns (docs/design/flush), light and dark, as checked in:
/// `mac-{threads,inspector,collapsed,split,narrow-peek}-{light,dark}.png` in
/// `$FROG_SNAPSHOT_DIR`, else `$TMPDIR/frog-snapshots/flush`. Run with
/// `TEST_RUNNER_FROG_SNAPSHOT_DIR=<repo>/docs/design/flush` to refresh the checked-in images.
///
/// The window is the app's: the real `WorkspaceView` with its toolbar bridged into a titled,
/// unified window, so the title bar's row, the traffic lights and the toolbar's items are in
/// the picture. It's ordered in hidden (`orderInForTest`): never seen, never key. Its sessions,
/// account and network are staged, so the images carry nothing of this Mac's.
@MainActor
final class FlushSnapshotTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/demo")

    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots/flush")
    }

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 120
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func s(_ id: String, _ title: String, ago minutes: Double, repo: String = "frog") -> SessionInfo {
            let t = now - Int64(minutes * 60_000)
            return SessionInfo(id: id, modified: t, created: t - 600_000, model: "anthropic/claude-opus-5.5",
                               firstInput: nil, title: title, end: .complete, forkedFrom: nil,
                               cwd: "/Users/me/Developer/\(repo)")
        }
        Library.shared.stage(sessions: [
            s("a", "Fix the fizzbuzz tests", ago: 1),
            s("b", "Flush sidebars", ago: 20),
            s("c", "Composer status line", ago: 90),
            s("d", "Timeline rail labels", ago: 600, repo: "web"),
            s("e", "Docs search", ago: 1500, repo: "web"),
        ], live: ["b": .waiting, "d": .running])
        CloudAccount.shared.stage(CloudAccount.Me(name: "Sam Frog", handle: nil, image: nil, google: nil, email: nil,
                                                  credit_cents: 1250, subscription: nil))
        Devices.shared.hideOffer = true
    }

    override func tearDown() {
        Library.shared.unstage()
        CloudAccount.shared.unstage()
        Devices.shared.hideOffer = false
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func show(_ pane: Pane, inspector: Bool) throws {
        pane.workspace.testShow(try FlushColumnsTests.conversationWithChanges(folder))
        pane.showChanges = inspector
    }

    private func render(_ name: String, width: CGFloat = 1440, height: CGFloat = 860, sessionsOpen: Bool = true,
                        _ setup: (Panes) throws -> Void) throws {
        for (look, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let panes = Panes(Workspace(folder: folder, fresh: true))
            defer { panes.stopAll() }
            try setup(panes)
            panes.focus(panes.items[0])
            let host = NSHostingView(rootView: WorkspaceView(panes: panes, sessionsOpen: sessionsOpen)
                .font(.frog(size: 13))
                .frame(minWidth: 720, minHeight: 480))
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
                             styleMask: [.titled, .resizable, .fullSizeContentView, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: look)
            w.toolbarStyle = .unified
            w.contentView = host
            w.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            w.orderInForTest()
            defer { w.close() }
            pump(1.5)
            // The whole window, title bar included: the theme frame holds the toolbar.
            let frame = try XCTUnwrap(host.superview)
            frame.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: outDir.appending(path: "mac-\(name)-\(suffix).png"))
        }
    }

    /// The thread with the sidebar docked and the inspector closed.
    func testThreads() throws {
        try render("threads") { try show($0.items[0], inspector: false) }
    }

    /// The inspector docked at the window's right edge.
    func testInspector() throws {
        try render("inspector") { try show($0.items[0], inspector: true) }
    }

    /// The sidebar collapsed, so gone: its toggle (with the dot for the waiting conversation)
    /// and New session beside the traffic lights, the inspector docked.
    func testCollapsed() throws {
        try render("collapsed", sessionsOpen: false) { try show($0.items[0], inspector: true) }
    }

    /// Two panes, each with its inspector: the left one has hairlines on both sides. The sidebar
    /// is folded to its rail: a window is clamped to the screen (1920 pt here), and two docked
    /// inspectors beside the full list would squeeze both columns under `minSplitColumn`.
    func testSplit() throws {
        try render("split", width: 1920, sessionsOpen: false) { panes in
            try show(panes.items[0], inspector: true)
            panes.split(nil, on: .right, window: nil)
            try show(panes.items[1], inspector: true)
        }
    }

    /// Too narrow to dock: the inspector floats over the conversation, flush to the right edge.
    func testNarrowPeek() throws {
        try render("narrow-peek", width: 900) { panes in
            try show(panes.items[0], inspector: false)
            panes.items[0].peekChanges = true
        }
    }
}

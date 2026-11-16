import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Documentation mode in the real window (docs/design/app-shell.md): going in and coming back
/// keeps the thread, its draft and the inspector's tab, because nothing under the page is torn
/// down. Also renders the mode, dark and light, for docs/design/app-shell/
/// (`$FROG_SNAPSHOT_DIR` or `$TMPDIR/frog-snapshots`, `docs-<state>-<look>.png`).
@MainActor
final class DocsModeTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// A window showing a conversation with the inspector open on Changes. Offscreen: ordering
    /// a window front hangs SwiftUI's key-view loop on macOS 27 with the inspector's glass (#384).
    private func window(_ panes: Panes, size: CGSize = CGSize(width: 1280, height: 800),
                        appearance: NSAppearance.Name = .darkAqua) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.6)
        host.layoutSubtreeIfNeeded()
        return (w, host)
    }

    private func panesWithThread() -> (Panes, Conversation) {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "docs-demo")
        panes.focused.workspace.testShow(c)
        panes.focused.showChanges = true
        c.panes.selected = .changes
        return (panes, c)
    }

    func testModeRemembersItsPage() {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        defer { panes.stopAll() }
        XCTAssertEqual(panes.mode, .threads)
        panes.showDocs("install")
        XCTAssertEqual(panes.mode, .docs)
        panes.backToApp()
        XCTAssertEqual(panes.mode, .threads)
        panes.showDocs()
        XCTAssertEqual(panes.docsPage, "install", "the window keeps its last page")
        panes.showDocs("web-search-and-fetch")
        XCTAssertEqual(panes.docsPage, "web-search-and-fetch")
    }

    /// In and out: the same conversation, the same composer text view with the same draft, the
    /// same inspector tab and card. Identity, not equality: a rebuilt composer restoring its
    /// draft from disk would pass an equality check (and the test host keeps drafts off disk).
    func testEnteringAndLeavingKeepsThreadDraftAndTab() throws {
        let (panes, c) = panesWithThread()
        defer { panes.stopAll() }
        let (w, _) = window(panes)
        defer { w.close() }
        let pane = panes.focused
        let tv = try XCTUnwrap(pane.ui.composer?.textView, "the composer didn't come up")
        tv.insertText("half a thought", replacementRange: NSRange(location: 0, length: 0))
        pump(0.2)
        XCTAssertEqual(tv.string, "half a thought")

        panes.showDocs()
        pump(0.6)
        XCTAssertEqual(panes.mode, .docs)
        XCTAssertTrue(pane.ui.composer?.textView === tv, "the composer stays mounted under the page")

        panes.backToApp()
        pump(0.6)
        XCTAssertEqual(panes.mode, .threads)
        XCTAssertTrue(panes.focused === pane)
        XCTAssertTrue(pane.conversation === c, "the same thread")
        XCTAssertTrue(pane.ui.composer?.textView === tv, "the same composer")
        XCTAssertEqual(pane.ui.composer?.textView?.string, "half a thought", "the same draft")
        XCTAssertEqual(c.panes.selected, .changes, "the same inspector tab")
        XCTAssertTrue(pane.showChanges, "the inspector is still open")
    }

    /// The docs sidebar and a page, as the window draws them, and the sidebar searching.
    func testRenderDocsMode() throws {
        let docs = try XCTUnwrap(AppDocs.bundled)
        let first = try XCTUnwrap(docs.pages.first)
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let (panes, _) = panesWithThread()
            defer { panes.stopAll() }
            // Straight into the mode: the thread list would show this Mac's real sessions (the
            // test host reads them), which don't belong in checked-in images.
            panes.showDocs(first.slug)
            let (w, host) = window(panes, appearance: look)
            pump(0.6)
            try snapshot(host, "docs-page-\(name)")
            w.close()

            // The sidebar searching, on its own at the sidebar's size.
            let sidebar = DocsSidebar(docs: docs, selected: first.slug, maxHeight: 560, query: "web",
                                      open: { _ in }, back: {})
                .frame(width: WorkspaceView.sessionsWidth, height: 560)
                .background(Tokens.sidebar, in: .rect(cornerRadius: 12))
                .padding(12)
                .background(Tokens.canvas)
            try render(sidebar, size: CGSize(width: WorkspaceView.sessionsWidth + 24, height: 584),
                       to: "docs-search-\(name)", appearance: look)
        }
        print("snapshots: \(outDir.path)")
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        try snapshot(host, name)
        window.close()
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Renders the real window layout with the inspector card up, to see the bug in the pane
/// card's layout without launching the app.
@MainActor
final class PaneCardRenderTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var outDir: URL {
        FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// The window as the app builds it: a workspace showing a conversation, the inspector
    /// docked, with a terminal and preview open.
    func testRenderWindowWithCard() throws {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        defer { panes.stopAll() }
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "demo")
        panes.focused.workspace.testShow(c)
        panes.focused.showChanges = true
        c.panes.openTerminal(cwd: URL(fileURLWithPath: "/tmp/demo"))
        c.panes.openPreview()
        if let t = c.panes.panes.first(where: { $0.kind == .terminal }) {
            c.panes.apply(.paneOpened(id: "t1", kind: .terminal, title: "zsh", cwd: "/tmp/demo", url: nil))
        }
        if let p = c.panes.panes.first(where: { $0.kind == .preview }) {
            c.panes.apply(.paneOpened(id: "p1", kind: .preview, title: "Demo", cwd: nil, url: nil))
        }
        c.panes.selected = .changes
        panes.focus(panes.focused)

        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(minWidth: 900, minHeight: 600))
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1500, height: 900),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        pump(1.5)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "window-card.png"))
        print("snapshots: \(outDir.path)")
        w.close()
    }
}

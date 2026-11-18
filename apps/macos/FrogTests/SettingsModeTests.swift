import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Settings as a mode of the shell (docs/design/app-shell.md › Settings): the sections and rows
/// come from design/settings.json, the list the web draws too; ⌘, and frog://settings/<section>
/// open a section in the window; going in and out keeps the thread. Also renders the mode, dark
/// and light, for docs/design/app-shell/ (`$FROG_SNAPSHOT_DIR` or `$TMPDIR/frog-snapshots`,
/// `mac-settings-<section>-<look>.png`).
@MainActor
final class SettingsModeTests: XCTestCase {
    private let catalog = SettingsCatalog.bundled

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    func testTheListIsBundledWithNineSectionsInOrder() {
        XCTAssertEqual(catalog.sections.map(\.label),
                       ["General", "Appearance", "Models", "Permissions", "Connections", "Shortcuts", "Usage", "Account", "Billing"])
        XCTAssertFalse(catalog.rows.isEmpty)
    }

    /// One source: every row the Mac draws has a control here, and nothing here is for a row the
    /// list doesn't give the Mac (the web's own, or one marked not yet on the Mac).
    func testEveryMacRowHasAControlAndNoneIsExtra() {
        for s in catalog.sections where !SettingsBindings.legacySections.contains(s.id) {
            for r in catalog.macRows(in: s.id) where SettingsBindings.drawnBy[r.id] == nil {
                XCTAssertNotNil(SettingsBindings.control(for: r), "\(r.id) has no control on the Mac")
            }
        }
        for r in catalog.rows where r.platform == .web || r.notYet?["mac"] != nil {
            XCTAssertNil(SettingsBindings.control(for: r), "\(r.id) isn't the Mac's, yet it has a control")
        }
        for (row, by) in SettingsBindings.drawnBy {
            XCTAssertEqual(catalog.row(row)?.section, catalog.row(by)?.section, "\(row) is drawn by \(by), in its section")
        }
    }

    /// Board 7's cuts aren't drawn: no "New messages use", no second energy switch in Appearance,
    /// no Lend section, no list of four mode explanations.
    func testCutRowsAreGone() {
        let labels = catalog.rows.map(\.label)
        XCTAssertFalse(labels.contains("New messages use"))
        XCTAssertFalse(labels.contains("Show cloud models in the picker"))
        XCTAssertFalse(labels.contains("Lend this Mac"))
        XCTAssertNil(catalog.sections.first { $0.id == "lend" })
        XCTAssertFalse(catalog.macRows(in: "appearance").contains { $0.label.localizedCaseInsensitiveContains("energy") })
        XCTAssertEqual(catalog.macRows(in: "general").first?.id, "notifications", "Notifications moved to General")
    }

    func testModeRemembersItsSectionAndTakesOldNames() {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        defer { panes.stopAll() }
        panes.showSettings()
        XCTAssertEqual(panes.mode, .settings)
        XCTAssertEqual(panes.settingsSection, "account", "Account the first time")
        panes.showSettings("mcp")
        XCTAssertEqual(panes.settingsSection, "connections")
        panes.backToApp()
        XCTAssertEqual(panes.mode, .threads)
        panes.showSettings()
        XCTAssertEqual(panes.settingsSection, "connections", "the window keeps its last section")
        panes.showSettings("energy")
        XCTAssertEqual(panes.settingsSection, "usage")
        panes.showSettings("nonsense")
        XCTAssertEqual(panes.settingsSection, "usage", "an unknown name keeps the last section")
    }

    func testSettingsLinks() {
        XCTAssertEqual(catalog.section(for: URL(string: "frog://settings/billing")!), "billing")
        XCTAssertEqual(catalog.section(for: URL(string: "frog://settings/lend")!), "models")
        XCTAssertEqual(catalog.section(for: URL(string: "frog://settings")!), "account")
        XCTAssertNil(catalog.section(for: URL(string: "frog://pair?code=1")!))
        XCTAssertNil(catalog.section(for: URL(string: "https://frog.toys/settings/billing")!))
    }

    /// A pending request (⌘, with no window, a link before a window is up) is taken once.
    func testAPendingRequestIsTakenOnce() {
        SettingsRequest.pending = "billing"
        XCTAssertEqual(SettingsRequest.take(), "billing")
        XCTAssertNil(SettingsRequest.take())
    }

    /// In and out of Settings: the same composer with the same draft, as with Documentation.
    func testEnteringAndLeavingKeepsTheDraft() throws {
        let (panes, c) = panesWithThread()
        defer { panes.stopAll() }
        let (w, _) = window(panes)
        defer { w.close() }
        let pane = panes.focused
        let tv = try XCTUnwrap(pane.ui.composer?.textView, "the composer didn't come up")
        tv.insertText("half a thought", replacementRange: NSRange(location: 0, length: 0))
        pump(0.2)
        panes.showSettings("appearance")
        pump(0.6)
        XCTAssertTrue(pane.ui.composer?.textView === tv, "the composer stays mounted under the page")
        panes.backToApp()
        pump(0.6)
        XCTAssertTrue(pane.conversation === c)
        XCTAssertEqual(pane.ui.composer?.textView?.string, "half a thought")
    }

    /// The window in Settings mode, one image per redrawn section, dark and light.
    func testRenderSettingsMode() throws {
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for section in ["general", "appearance", "permissions", "shortcuts"] {
                let (panes, _) = panesWithThread()
                defer { panes.stopAll() }
                panes.showSettings(section)
                let (w, host) = window(panes, appearance: look)
                pump(0.6)
                try snapshot(host, "mac-settings-\(section)-\(name)")
                w.close()
            }
        }
        print("snapshots: \(outDir.path)")
    }

    // MARK: Helpers

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
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "settings-demo")
        panes.focused.workspace.testShow(c)
        return (panes, c)
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }
}

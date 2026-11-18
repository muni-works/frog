import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The flow driver itself, on flows that need no engine: the palette from the toolbar, the menu
/// bar and its shortcut, a palette command typed and run, and the title menu's Delete… backed
/// out of. Each drives the real window content, hidden.
@MainActor
final class FlowDriverTests: XCTestCase {
    private var w: FlowWindow!
    private let folder = URL(fileURLWithPath: "/tmp/frog-flow-driver")

    override func setUpWithError() throws {
        executionTimeAllowance = 120
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        w = FlowWindow(folder: folder)
        try w.requireReadable()
    }

    override func tearDown() {
        w?.close()
        w = nil
    }

    /// The window is in the tree with its content and toolbar, and nothing of it is on screen.
    func testTheWindowIsReadableAndHidden() {
        XCTAssertTrue(w.shows("What should we work on?") || w.shows("what shall we"), "\(w.texts.prefix(30))")
        XCTAssertNotNil(w.find(.button("Commands")), "the toolbar's controls are in the tree")
        XCTAssertFalse(w.window.isSeenByUser)
        XCTAssertFalse(NSApp.isActive)
    }

    /// Flow tests never see the Mac's real Frog Cloud account (the test host shares the login
    /// Keychain): the footer offers sign-in.
    func testTheWindowIsSignedOut() {
        XCTAssertFalse(CloudAccount.shared.signedIn)
        XCTAssertFalse(w.texts.contains { $0.contains("credit") }, "an account showed: \(w.texts.filter { $0.contains("credit") })")
    }

    func test_open_palette() {
        XCTAssertNil(w.find(.field(placeholder: "Type a command")))
        w.press(.button("Commands"))
        XCTAssertNotNil(w.element(.field(placeholder: "Type a command")), "the palette opened")
        XCTAssertTrue(w.shows("New Session"), "it lists commands")
    }

    func test_open_palette__fromMenuBar() {
        w.menuBar("View", "Command Palette")
        XCTAssertNotNil(w.element(.field(placeholder: "Type a command")))
    }

    func test_open_palette__shortcut() {
        XCTAssertTrue(w.shortcut("k"), "⌘K reached an enabled menu item")
        XCTAssertNotNil(w.element(.field(placeholder: "Type a command")))
    }

    /// A shortcut nothing enables isn't taken: ⌥⌘Z (Undo Last Turn) with no turn to undo.
    func testADisabledShortcutIsNotTaken() {
        XCTAssertFalse(w.shortcut("z", [.command, .option]))
    }

    func test_toggle_changes_from_palette() {
        XCTAssertFalse(w.panes.focused.showChanges)
        w.press(.button("Commands"))
        w.type("Show Changes", into: .field(placeholder: "Type a command"), submit: true)
        XCTAssertTrue(w.waitUntil { self.w.panes.focused.showChanges }, "Show Changes ran")
        XCTAssertNil(w.find(.field(placeholder: "Type a command")), "the palette closed")
    }

    /// The title menu offers Rename… only once the conversation has a session.
    func testTitleMenuRenameNeedsASession() throws {
        w.workspace.testShow(Conversation(folder: folder, link: nil, replay: false, session: nil))
        w.pump(0.3)
        let menu = try XCTUnwrap(w.menu(.text("New Conversation")))
        XCTAssertEqual(menu.titles, ["Rename…"])
        XCTAssertFalse(menu.isEnabled("Rename…"))
    }

    /// Delete… asks first; Cancel leaves the conversation where it was.
    func test_delete_cancel() throws {
        let c = Conversation(folder: folder, link: nil, replay: false, session: "flow-delete-cancel")
        w.workspace.testShow(c)
        w.pump(0.3)
        let menu = try XCTUnwrap(w.menu(.text(w.workspace.currentTitle ?? "New Conversation")))
        XCTAssertEqual(menu.titles, ["Rename…", "Archive", "Delete…"])
        menu.choose("Delete…")
        XCTAssertNotNil(w.element(.text("Its log moves to the Trash.")), "the dialog asks")
        XCTAssertFalse(w.window.attachedSheet?.isSeenByUser ?? false, "its sheet stays hidden")
        w.press(.sheetButton("Cancel"))
        XCTAssertTrue(w.waitUntil { self.w.find(.text("Its log moves to the Trash.")) == nil }, "the dialog went")
        XCTAssertEqual(w.conversation?.sessionID, "flow-delete-cancel", "the conversation is still open")
    }
}


/// On CI a flow test that can't read its window fails rather than skips (`requireReadable`), so
/// a green run means the flows ran. This one says so on its own, by name.
@MainActor
final class FlowWindowCanaryTests: XCTestCase {
    func testTheHostedWindowIsReadable() throws {
        let w = FlowWindow(folder: URL(fileURLWithPath: NSTemporaryDirectory()))
        defer { w.close() }
        try w.requireReadable()
        XCTAssertNotNil(w.find(.button("Commands")))
    }
}

import AppKit
import XCTest
@testable import Frog

/// A flow test: the real window content (`FlowWindow`), hidden, on a project the real bundled
/// engine works in against a scripted model (`ScriptedEngine`). Each test is named for the flow
/// it drives (docs/testing/feature-map) and takes the user's steps: what it presses, types and
/// chooses is what a person would.
@MainActor
class FlowTestCase: XCTestCase {
    var engine: ScriptedEngine!
    var w: FlowWindow!
    var c: Conversation? { w.conversation }

    /// Opens the window on a fresh project. Call first in each test.
    func open(mode: Mode = .default, config: [String] = [], sharedHome: Bool = false, signedOut: Bool = true) throws {
        executionTimeAllowance = 120
        UserDefaults.standard.removeObject(forKey: "yoloConfirmed")
        engine = try ScriptedEngine.startNow(mode: mode, config: config, sharedHome: sharedHome)
        w = FlowWindow(folder: engine.folder, signedOut: signedOut)
        try w.requireReadable()
        if worktreeOff { useTheCheckout() }
    }

    /// Flows here send in the project's own checkout: the where menu's New worktree, off (a
    /// worktree session's first message goes from a new composer in the worktree, its own flow).
    var worktreeOff = true

    func useTheCheckout(file: StaticString = #filePath, line: UInt = #line) {
        w.press(.id("composer.where"), file: file, line: line)
        w.press(.text("New worktree"), file: file, line: line)
        if w.find(.text("New worktree")) != nil { w.press(.id("composer.where"), file: file, line: line) }
    }

    override func tearDown() {
        // A card left up would stay in the Dock badge's count for the rest of the run.
        if let c = w?.conversation, c.permission != nil { c.answer(.deny); w.pump(0.3) }
        w?.close()
        engine?.stop()
        w = nil
        engine = nil
        UserDefaults.standard.removeObject(forKey: "yoloConfirmed")
    }

    /// Waits for `ok`, failing with `what` if it never holds.
    @discardableResult
    func expect(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) -> Bool {
        let held = w.waitUntil(timeout: timeout, ok)
        if !held { XCTFail("\(what); on screen: \(w.texts.suffix(40))", file: file, line: line) }
        return held
    }

    /// Sends a first message and waits for its turn to end, so the conversation has a session
    /// and a running engine.
    func startConversation(_ prompt: String = "hello", reply: String = "Hello from the script.", file: StaticString = #filePath, line: UInt = #line) {
        engine.model.add(.reply(.text(reply)))
        w.send(prompt, file: file, line: line)
        expect("the first turn ended", file: file, line: line) { self.c?.turns.last?.finished == true && self.c?.sessionID != nil }
    }
}

/// Permission cards, interrupt, undo, the quiet child.
final class ConversationFlowTests: FlowTestCase {
    // MARK: Permission card

    /// A command that leaves the sandbox: Ask mode always cards it.
    private func scriptCommand(_ file: String = "made-by-frog", then reply: String = "Made it.") {
        engine.model.add(
            .reply(.tool("Bash", ["command": "touch \(file)", "unsandboxed": true])),
            .afterTool(.text(reply))
        )
    }

    func test_allow_once() throws {
        try open(mode: .default)
        scriptCommand()
        w.send("make a file")
        w.element(.id("permission.allow"))
        XCTAssertNil(engine.file("made-by-frog"), "nothing ran before the answer")
        w.press(.id("permission.allow"))
        expect("the command ran") { self.engine.file("made-by-frog") != nil }
        expect("the turn went on to the answer") { self.c?.turns.last?.finished == true && self.engine.log(self.c?.sessionID).contains("Made it.") }
        XCTAssertNil(w.find(.id("permission.allow")), "the card went")
    }

    func test_deny() throws {
        try open(mode: .default)
        scriptCommand()
        w.send("make a file")
        w.press(.id("permission.deny"))
        expect("the card went") { self.w.find(.id("permission.allow")) == nil }
        expect("the turn ended") { self.c?.turns.last?.finished == true }
        XCTAssertNil(engine.file("made-by-frog"), "a denied command never runs")
    }

    /// "Allow all edits this session" from the ⋯ menu: the next edit runs without a card. (A
    /// command that leaves the sandbox offers no standing allow.)
    func test_always_allow() throws {
        try open(mode: .default)
        engine.model.add(
            .reply(.tool("Write", ["file_path": "first", "content": "1\n"])),
            .afterTool(.tool("Write", ["file_path": "second", "content": "2\n"])),
            .afterTool(.text("Both made."))
        )
        w.send("make two files")
        let more = try XCTUnwrap(w.menu(.id("permission.more")))
        XCTAssertTrue(more.titles.contains { $0.hasPrefix("Allow all edits") }, "\(more.titles)")
        more.choose(startingWith: "Allow all edits")
        expect("the first command ran") { self.engine.file("first") != nil }
        expect("the second ran without asking") { self.engine.file("second") != nil }
        expect("the turn finished") { self.c?.turns.last?.finished == true && self.engine.log(self.c?.sessionID).contains("Both made.") }
    }

    func test_deny_with_note() throws {
        try open(mode: .default)
        scriptCommand()
        w.send("make a file")
        let more = try XCTUnwrap(w.menu(.id("permission.more")))
        more.choose("Deny with a note…")
        w.type("use the project's script instead", into: .field(placeholder: "Tell the agent why"), submit: true)
        expect("the turn went on") { self.engine.model.requests.contains { $0.contains("use the project's script instead") } }
        XCTAssertNil(engine.file("made-by-frog"))
    }

    // MARK: Interrupt

    func test_interrupt_running_turn() throws {
        try open()
        engine.model.add(.reply(.held("too late")))
        w.send("take your time")
        expect("the turn is running") { self.c?.busy == true && self.w.find(Query(label: "Stop (Esc)")) != nil }
        w.press(.id("composer.action"))
        expect("the turn stopped") { self.c?.turns.last?.end == .cancelled }
        XCTAssertFalse(w.shows("too late"))
    }

    func test_interrupt_shortcut() throws {
        try open()
        engine.model.add(.reply(.held("too late")))
        w.send("take your time")
        expect("the turn is running") { self.c?.busy == true }
        w.menuBar("Session", "Interrupt")
        expect("the turn stopped") { self.c?.turns.last?.end == .cancelled }
    }

    /// While a card is up ⌘. is Deny, so Interrupt is off.
    func test_interrupt_disabled_under_card() throws {
        try open(mode: .default)
        scriptCommand()
        w.send("make a file")
        w.element(.id("permission.allow"))
        let item = try XCTUnwrap(w.menuBarItem(["Session", "Interrupt"]))
        item.menu?.update()
        XCTAssertFalse(item.isEnabled)
    }

    // MARK: Undo

    /// Edit › Undo Turn 1… puts the file the turn changed back as it was.
    func test_undo_last_turn() throws {
        try open(mode: .acceptEdits)
        engine.model.add(
            .reply(.tool("Read", ["file_path": "README.md"])),
            .afterTool(.tool("Write", ["file_path": "README.md", "content": "frog rewrote this\n"])),
            .afterTool(.text("Rewrote it."))
        )
        w.send("rewrite the readme")
        expect("the turn ended") { self.c?.turns.last?.finished == true }
        XCTAssertEqual(engine.file("README.md"), "frog rewrote this\n")
        w.menuBar("Edit", "Undo Turn")
        w.press(.sheetButton("Undo Changes"))
        expect("the file is back", timeout: 30) { self.engine.file("README.md") == "hello\n" }
    }

    func test_undo_disabled() throws {
        try open()
        startConversation()
        let item = try XCTUnwrap(w.menuBarItem(["Edit", "Undo Last Turn"]))
        item.menu?.update()
        XCTAssertFalse(item.isEnabled, "a turn that changed no files has nothing to undo")
    }

    // MARK: The quiet child

    /// A question's option: its button reads "2, Stop it and carry on, <detail>".
    static func option(_ label: String) -> Query { Query(text: label, role: kAXButtonRole as String) }

    private func quietChild() throws {
        try open(config: ["child_quiet_secs = 2"])
        engine.model.add(
            .reply(.tool("Task", ["description": "find the parser", "prompt": "QUIET-CHILD: find the parser"])),
            .after("QUIET-CHILD", .silent),
            .afterTool(.text("Carried on without it."))
        )
        w.send("delegate it")
    }

    func test_quiet_child_asks() throws {
        try quietChild()
        expect("the question", timeout: 30) { self.w.shows("find the parser") && self.w.find(Self.option("Keep waiting")) != nil }
        XCTAssertNotNil(w.find(Self.option("Stop it and carry on")))
    }

    func test_stop_and_carry_on() throws {
        try quietChild()
        w.element(Self.option("Stop it and carry on"), timeout: 30)
        w.press(Self.option("Stop it and carry on"))
        expect("the parent carried on", timeout: 30) { self.engine.log(self.c?.sessionID).contains("Carried on without it.") }
        XCTAssertNil(w.find(Self.option("Keep waiting")), "the question went")
    }
}

/// Modes: the composer chip, the menu bar, the palette.
final class ModeFlowTests: FlowTestCase {
    private func mode() -> Mode? { c?.status?.mode }

    func test_pick_mode_from_chip() throws {
        try open(mode: .auto)
        startConversation()
        for (id, want) in [("mode.default", Mode.default), ("mode.accept_edits", .acceptEdits), ("mode.auto", .auto)] {
            w.press(.id("composer.mode"))
            w.press(.id(id))
            expect("the mode is \(want.label)") { self.mode() == want }
        }
    }

    /// Yolo from the chip asks first: nothing changes until "Use Yolo".
    func test_confirm_yolo() throws {
        try open(mode: .auto)
        startConversation()
        w.press(.id("composer.mode"))
        w.press(.id("mode.yolo"))
        w.element(.button("Use Yolo"))
        XCTAssertEqual(mode(), .auto, "not yet")
        w.press(.button("Use Yolo"))
        expect("Yolo is on") { self.mode() == .yolo }
    }

    func test_mode_from_menu_bar() throws {
        try open(mode: .auto)
        startConversation()
        for want in [Mode.default, .acceptEdits, .auto] {
            w.menuBar("Model", want.label)
            expect("the mode is \(want.label)") { self.mode() == want }
        }
    }

    /// Reported at v0.7.0: Model › Yolo (⌃⌘4) turns Yolo on with no confirmation, where the
    /// chip asks first.
    func test_mode_from_menu_bar__yoloAsksFirst() throws {
        try open(mode: .auto)
        startConversation()
        w.menuBar("Model", "Yolo")
        w.pump(0.5)
        XCTExpectFailure("v0.7.0 bug: the menu bar turns on Yolo without the chip's confirmation")
        XCTAssertNotEqual(mode(), .yolo, "Yolo waits for a confirmation")
        XCTAssertNotNil(w.find(.button("Use Yolo")), "the composer asks")
    }

    func test_mode_or_model_from_palette() throws {
        try open(mode: .auto)
        startConversation()
        w.press(.button("Commands"))
        w.type("Mode: Accept Edits", into: .field(placeholder: "Type a command"), submit: true)
        expect("the mode is Accept Edits") { self.mode() == .acceptEdits }
    }

    /// Reported at v0.7.0: "Mode: Yolo" from the palette skips the confirmation too.
    func test_mode_or_model_from_palette__yoloAsksFirst() throws {
        try open(mode: .auto)
        startConversation()
        w.press(.button("Commands"))
        w.type("Mode: Yolo", into: .field(placeholder: "Type a command"), submit: true)
        w.pump(0.5)
        XCTExpectFailure("v0.7.0 bug: the palette turns on Yolo without the chip's confirmation")
        XCTAssertNotEqual(mode(), .yolo, "Yolo waits for a confirmation")
    }

    /// Reported at v0.7.0: the chip's tooltip names ⌘., which is Interrupt (and Deny on a card).
    func testModeChipTooltipNamesNoOtherCommandsShortcut() throws {
        try open()
        let chip = try XCTUnwrap(w.element(.id("composer.mode")))
        XCTExpectFailure("v0.7.0 bug: the mode chip's tooltip says ⌘., the Interrupt shortcut")
        XCTAssertFalse(chip.help?.contains("⌘.") ?? false, "tooltip: \(chip.help ?? "none")")
    }
}

/// The composer's @ mention, the title menu's rename and delete.
final class ComposerAndTitleFlowTests: FlowTestCase {
    func test_mention_a_file() throws {
        try open()
        w.typeInComposer("look at @")
        // The project's files load the first time a mention starts; a person types on meanwhile.
        expect("the project's files are indexed") { !self.w.workspace.files.isEmpty }
        w.typeInComposer("READ")
        expect("the file list offers README.md") { self.w.shows("README.md") }
        w.pressReturnInComposer()
        expect("the mention is in the draft") { self.w.composerField?.string.contains("@README.md") == true }
        XCTAssertTrue(c?.turns.isEmpty ?? true, "Return picked the file; it didn't send")
    }

    func test_rename_from_title() throws {
        try open()
        startConversation()
        let menu = try XCTUnwrap(w.menu(.id("title.menu")))
        menu.choose("Rename…")
        // In place (docs/design/chrome/spec.md, 3): the title becomes a field; Return saves.
        w.type("Renamed by a flow", into: .id("title.field"), submit: true)
        expect("the title row reads the new title") { self.w.find(Query(id: "title.menu", text: "Renamed by a flow")) != nil }
        expect("the session took it") { self.c?.title == "Renamed by a flow" }
    }

    /// Delete… → Move to Trash: the log goes to the Trash and the pane starts afresh.
    func test_delete_from_title() throws {
        try open(sharedHome: true)
        // The Trash, as Library.delete uses it: a scratch folder here, not the user's.
        let trash = engine.folder.deletingLastPathComponent().appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        Library.trash = { try? FileManager.default.moveItem(at: $0, to: trash.appending(path: $0.lastPathComponent)) }
        defer { Library.trash = nil }
        startConversation()
        let id = try XCTUnwrap(c?.sessionID)
        let log = engine.sessionsDir.appending(path: "\(id).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        let menu = try XCTUnwrap(w.menu(.id("title.menu")))
        menu.choose("Delete…")
        w.press(.sheetButton("Move to Trash"))
        expect("the log left the sessions folder") { !FileManager.default.fileExists(atPath: log.path) }
        expect("the pane shows a fresh conversation") { self.c?.sessionID != id }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appending(path: "\(id).jsonl").path), "the log went to the Trash")
    }
}

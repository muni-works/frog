import Foundation
import XCTest
@testable import Frog

/// The scripted engine itself: each kind of scripted turn reaches the app the way a real model's
/// would, through the real bundled engine. Driven through the store (no window), so these run
/// whether or not the screen can be read; the flow tests drive the same turns through the window.
@MainActor
final class ScriptedEngineTests: XCTestCase {
    private var engine: ScriptedEngine!
    private var panes: Panes!

    private func start(mode: Mode = .default, config: [String] = []) async throws -> Conversation {
        engine = try await ScriptedEngine.start(mode: mode, config: config)
        panes = Panes(Workspace(folder: engine.folder, fresh: true))
        return try XCTUnwrap(panes.focused.workspace.conversation)
    }

    override func tearDown() async throws {
        panes?.stopAll()
        engine?.stop()
        Library.shared.refresh()
    }

    private func waitFor(_ what: String, _ seconds: Double = 20, _ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds * TestRunner.slack)
        while !ok(), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(ok(), what)
    }

    func testAScriptedAnswer() async throws {
        let c = try await start()
        engine.model.script(.reply(.text("Scripted hello.")))
        c.submit("say hello")
        await waitFor("the turn ended") { c.turns.last?.finished == true }
        XCTAssertEqual(c.turns.last?.end, .complete)
        XCTAssertTrue(engine.log(c.sessionID).contains("Scripted hello."), "the answer is the script's")
    }

    /// A tool call in Ask mode stops on a permission card; allowing it runs the tool, and the
    /// script's next step answers the tool's result.
    func testAToolCallThatNeedsPermission() async throws {
        let c = try await start(mode: .default)
        engine.model.script(
            .reply(.tool("Bash", ["command": "touch made-by-frog", "unsandboxed": true])),
            .afterTool(.text("Made it."))
        )
        c.submit("make a file")
        await waitFor("a permission card") { c.permission != nil }
        XCTAssertEqual(c.permission?.name, "Bash")
        XCTAssertNil(engine.file("made-by-frog"), "nothing ran before the answer")
        c.answer(.allow)
        await waitFor("the turn ended") { c.turns.last?.finished == true }
        XCTAssertNotNil(engine.file("made-by-frog"), "the command ran once allowed")
    }

    func testAQuestion() async throws {
        let c = try await start()
        engine.model.script(
            .reply(.tool("Ask", ["question": "Which colour?", "options": [["label": "Green"], ["label": "Blue"]], "multi": false])),
            .after("Green", .text("Green it is."))
        )
        c.submit("pick a colour")
        await waitFor("the question") { c.question != nil }
        XCTAssertEqual(c.question?.question, "Which colour?")
        c.answer(question: ["Green"])
        await waitFor("the turn ended") { c.turns.last?.finished == true }
        XCTAssertTrue(engine.log(c.sessionID).contains("Green it is."))
    }

    /// A subagent whose model never answers: after `child_quiet_secs` the parent asks.
    func testAChildThatGoesQuiet() async throws {
        let c = try await start(config: ["child_quiet_secs = 2"])
        engine.model.script(
            .reply(.tool("Task", ["description": "find the parser", "prompt": "QUIET-CHILD: find the parser"])),
            .after("QUIET-CHILD", .silent)
        )
        c.submit("delegate it")
        await waitFor("the quiet-child question", 30) { c.question?.question.contains("find the parser") == true }
        XCTAssertEqual(c.question?.options.map(\.label), ["Keep waiting", "Stop it and carry on"])
    }

    func testAnError() async throws {
        let c = try await start()
        engine.model.script(.reply(.error(400, "scripted failure")))
        c.submit("fail please")
        await waitFor("the turn ended") { c.turns.last?.finished == true }
        guard case .error? = c.turns.last?.end else { return XCTFail("ended \(String(describing: c.turns.last?.end))") }
    }
}

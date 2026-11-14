import Foundation
import XCTest
@testable import Frog

/// The unified Mac/web layout: verb activity lines, plain notices, pooled model names, and
/// session row status.
final class OneLookTests: XCTestCase {
    func testVerbLines() {
        var read = ItemState(id: "1", kind: .tool(name: "Read", arg: "/Users/cam/frog/crates/x.rs"))
        read.done = true
        let r = VerbLine.of(read)
        XCTAssertEqual(r?.verb, "Read")
        XCTAssertEqual(r?.arg, "frog/crates/x.rs")

        var bash = ItemState(id: "2", kind: .tool(name: "Bash", arg: "cargo test\nmore"))
        bash.done = true
        // No gist yet: the command is the line ("Ran" would say it twice), and never "Used".
        let bashLine = VerbLine.of(bash)
        XCTAssertEqual(bashLine?.verb, "")
        XCTAssertEqual(bashLine?.arg, "cargo test")
        // The gist lands: it is the line, and the argument goes.
        bash.gist = "ran the suite in the worktree"
        let gisted = VerbLine.of(bash)
        XCTAssertEqual(gisted?.verb, "ran the suite in the worktree")
        XCTAssertNil(gisted?.arg)
        // A failure keeps its verb: the fact a gist would hide.
        var failedBash = ItemState(id: "2f", kind: .tool(name: "Bash", arg: "cargo test"))
        failedBash.done = true
        failedBash.gist = "ran the suite in the worktree"
        failedBash.result = Item.ToolResult(
            name: "Bash", arg: "cargo test", input: nil, outcome: .error, output: "1 test failed",
            display: nil, diff: nil, diagram: nil, present: nil, images: nil, app: nil, widget: nil)
        let failedLine = VerbLine.of(failedBash)
        XCTAssertEqual(failedLine?.verb, "Ran")
        XCTAssertEqual(failedLine?.arg, "cargo test")
        XCTAssertEqual(failedLine?.failed, true)

        var plan1 = ItemState(id: "3", kind: .tool(name: "TodoWrite", arg: "")); plan1.done = true
        var plan2 = ItemState(id: "4", kind: .tool(name: "TodoWrite", arg: "")); plan2.done = true
        var think = ItemState(id: "5", kind: .reasoning); think.done = true
        // A thought beside tools says nothing; plan updates stay one line. The bash item
        // carries the gist from the check above, so its line is the gist.
        let lines = VerbLine.lines([think, plan1, plan2, bash])
        XCTAssertEqual(lines.map(\.verb), ["Updated the plan", "ran the suite in the worktree"])
        XCTAssertEqual(VerbLine.lines([think]).first?.quiet, true)
    }

    func testDiagnosticNoticesStayOutOfTheComposer() {
        XCTAssertNil(Conversation.plainNotice("context window: 32768 tokens (from server); auto-compacting past 27852"))
        XCTAssertNil(Conversation.plainNotice("repo map limited to 20,000 files or 2 seconds"))
        XCTAssertEqual(Conversation.plainNotice("started a new conversation"), "Started a new conversation")
        XCTAssertNotNil(Conversation.plainNotice("Network allow-list: pypi.org allowed for the rest of this session."))
    }

    /// A tool the switch doesn't know (an MCP call) must never read "Used X": the raw
    /// argument is the line until a gist lands. Written to fail against the old default
    /// (`"Used \(ToolIcon.title(name))"`) — the red proof is in the PR body.
    func testUnknownToolNeverSaysUsed() {
        var mcp = ItemState(id: "m1", kind: .tool(name: "mcp__github__list_issues", arg: #"{"repo":"muni-works/frog"}"#))
        mcp.done = true
        let line = VerbLine.of(mcp)
        XCTAssertFalse(line?.verb.hasPrefix("Used") ?? false, "no tool row may read 'Used X': \(line?.verb ?? "")")
        XCTAssertEqual(line?.arg, #"{"repo":"muni-works/frog"}"#)
        // With a gist, the gist is the line and the raw arguments go.
        mcp.gist = "listed the open issues on frog"
        let gisted = VerbLine.of(mcp)
        XCTAssertEqual(gisted?.verb, "listed the open issues on frog")
        XCTAssertNil(gisted?.arg)
    }

    /// The row's `help` carries the raw truth: the command when the line is a gist, the full
    /// command when the line elides it.
    func testRowHelpCarriesTheRawCommand() {
        var bash = ItemState(id: "h1", kind: .tool(name: "Bash", arg: "cargo test -- --nocapture"))
        bash.done = true
        XCTAssertEqual(VerbLine.of(bash)?.helpText, "cargo test -- --nocapture")
        bash.gist = "ran the engine's suite"
        XCTAssertEqual(VerbLine.of(bash)?.helpText, "cargo test -- --nocapture")
    }

    @MainActor
    func testPooledModelNeverShowsItsHash() {
        XCTAssertEqual(Workspace.pooledName(spec: "node/80742a5cd76a", named: "Qwen3-8B"), "Qwen3 8B")
        XCTAssertEqual(Workspace.pooledName(spec: "node/80742a5cd76a", named: "80742a5cd76a"), "Shared model")
    }

    /// The sidebar row's second line ("scratchpad · 80742a5cd76a") named the model by its hash.
    @MainActor
    func testSessionRowNamesAPooledModelAsThePickerDoes() {
        ModelIdentity.rowName = { Workspace.modelName($0) }
        XCTAssertFalse(ModelIdentity.rowName("node/80742a5cd76a").contains("80742a5cd76a"))
        XCTAssertEqual(ModelIdentity.rowName("node/80742a5cd76a"), Workspace.modelName("node/80742a5cd76a"))
    }

    func testRowStatus() {
        let merged = ComposerModel.summary([pr(271, .merged)])!
        XCTAssertEqual(RowStatus.derive(live: .running, end: .complete), .running)
        XCTAssertEqual(RowStatus.derive(live: .waiting, end: nil), .needsYou)
        XCTAssertEqual(RowStatus.derive(live: nil, end: .failed), .failed)
        XCTAssertEqual(RowStatus.derive(live: nil, end: .complete, prs: merged), .pr(merged))
        XCTAssertNil(RowStatus.derive(live: nil, end: .complete))
    }

    private func pr(_ n: Int, _ state: ComposerModel.PrState) -> ComposerModel.Pr {
        .init(repo: "muni-works/frog", number: n, title: "t", state: state, checks: .init(ok: 0, total: 0))
    }
}

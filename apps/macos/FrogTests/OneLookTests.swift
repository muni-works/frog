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
        XCTAssertEqual(VerbLine.of(bash)?.verb, "Ran")
        XCTAssertEqual(VerbLine.of(bash)?.arg, "cargo test")

        var plan1 = ItemState(id: "3", kind: .tool(name: "TodoWrite", arg: "")); plan1.done = true
        var plan2 = ItemState(id: "4", kind: .tool(name: "TodoWrite", arg: "")); plan2.done = true
        var think = ItemState(id: "5", kind: .reasoning); think.done = true
        let lines = VerbLine.lines([think, plan1, plan2, bash])
        // A thought beside tools says nothing; plan updates stay one line.
        XCTAssertEqual(lines.map(\.verb), ["Updated the plan", "Ran"])
        XCTAssertEqual(VerbLine.lines([think]).first?.quiet, true)
    }

    func testDiagnosticNoticesStayOutOfTheComposer() {
        XCTAssertNil(Conversation.plainNotice("context window: 32768 tokens (from server); auto-compacting past 27852"))
        XCTAssertNil(Conversation.plainNotice("repo map limited to 20,000 files or 2 seconds"))
        XCTAssertEqual(Conversation.plainNotice("started a new conversation"), "Started a new conversation")
        XCTAssertNotNil(Conversation.plainNotice("Network allow-list: pypi.org allowed for the rest of this session."))
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

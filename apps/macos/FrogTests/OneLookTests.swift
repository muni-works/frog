import Foundation
import XCTest
@testable import Frog

/// The unified Mac/web layout: lines read from docs/design/transcript/verbs.json by the web's
/// rules, plain notices, pooled model names, and session row status.
final class OneLookTests: XCTestCase {
    // MARK: Lines (docs/design/transcript/spec.md, "Lines"; the words from verbs.json)

    private struct VerbTable: Decodable {
        struct Tool: Decodable { let tool: String; let aliases: [String]?; let live: String; let past: String; let created: String?; let object: String }
        struct Unknown: Decodable { let live: String; let past: String; let object: String }
        struct States: Decodable {
            struct Failed: Decodable { let verb: String }
            struct Denied: Decodable { let verb: String; let result: String }
            let failed: Failed
            let denied: Denied
        }
        let tools: [Tool]
        let unknown: Unknown
        let states: States
    }

    /// The shared verb table, as the web reads it.
    private func verbs() throws -> VerbTable {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/transcript/verbs.json")
        return try JSONDecoder().decode(VerbTable.self, from: Data(contentsOf: url))
    }

    private func step(_ id: String, _ name: String, _ arg: String, outcome: ToolOutcome? = .ok, output: String = "",
                      display: String? = nil, diff: FileDiff? = nil, tests: Item.TestRun? = nil, gist: String? = nil,
                      started: Date? = nil, ended: Date? = nil) -> ItemState {
        var item = ItemState(id: id, kind: .tool(name: name, arg: arg))
        item.done = outcome != nil
        item.gist = gist
        item.startedAt = started
        item.endedAt = ended
        if let outcome {
            item.result = Item.ToolResult(name: name, arg: arg, input: nil, outcome: outcome, output: output,
                                          display: display, diff: diff, diagram: nil, present: nil, images: nil, app: nil,
                                          widget: nil, tests: tests)
        }
        return item
    }

    /// Every tool in verbs.json, and every alias, reads its verbs and sets its object as the
    /// table says: running, finished, and through `Verbs` (generated from the same file).
    func testEveryToolReadsTheSharedVerbs() throws {
        let table = try verbs()
        for t in table.tools {
            for name in [t.tool] + (t.aliases ?? []) {
                let arg = t.object == "host" ? "https://docs.rs/rand/latest" : "x/y"
                let done = try XCTUnwrap(StepLine.of(step("d", name, arg)))
                XCTAssertEqual(done.verb, t.past, "\(name) finished")
                XCTAssertEqual(StepLine.of(step("r", name, arg, outcome: nil))?.verb, t.live, "\(name) running")
                XCTAssertEqual(done.mono, ["command", "path", "pattern", "tool"].contains(t.object), "\(name) mono")
                switch t.object {
                case "none": XCTAssertEqual(done.object, "", "\(name): the verb is the whole line")
                case "host": XCTAssertEqual(done.object, "docs.rs", "\(name): the host")
                default: XCTAssertEqual(done.object, arg, "\(name): the object as given")
                }
                let look = Verbs.look(name)
                XCTAssertEqual([look.live, look.past, look.created ?? "", look.object.rawValue], [t.live, t.past, t.created ?? "", t.object])
            }
        }
        // Write that made a file says so.
        let created = FileDiff(path: "a.rs", created: true, added: 3, removed: 0, hunks: [])
        XCTAssertEqual(StepLine.of(step("w", "Write", "a.rs", diff: created))?.verb, "Created")
        XCTAssertEqual(table.states.failed.verb, Verbs.failed)
        XCTAssertEqual(table.states.denied.verb, Verbs.denied)
        XCTAssertEqual(table.states.denied.result, Verbs.deniedResult)
    }

    /// Unknown and MCP tools read "Called" + the tool's title; never "Used".
    func testUnknownToolsAreCalledByTitle() throws {
        let table = try verbs()
        let mcp = try XCTUnwrap(StepLine.of(step("m", "mcp__github__list_issues", #"{"repo":"muni-works/frog"}"#)))
        XCTAssertEqual(mcp.verb, table.unknown.past)
        XCTAssertEqual(mcp.object, "github › list_issues")
        XCTAssertTrue(mcp.mono)
        XCTAssertEqual(mcp.title, #"{"repo":"muni-works/frog"}"#, "the argument opens / is the hover")
        XCTAssertEqual(StepLine.of(step("m", "Frobnicate", "x", outcome: nil))?.verb, table.unknown.live)
        XCTAssertEqual(StepLine.of(step("m", "Frobnicate", "x"))?.text, "Called Frobnicate")
    }

    /// A gist is the whole line of a successful finished step, and never shows on a failed or
    /// denied one.
    func testAGistIsTheLineOnlyWhenItWorked() {
        let ok = StepLine.of(step("g", "Bash", "cargo test", gist: "ran the suite in the worktree"))!
        XCTAssertEqual([ok.verb, ok.object, ok.gist], ["", "", "ran the suite in the worktree"])
        let failed = StepLine.of(step("g", "Bash", "cargo test", outcome: .error, gist: "ran the suite"))!
        XCTAssertEqual([failed.verb, failed.object, failed.gist], ["Failed", "cargo test", ""])
        let denied = StepLine.of(step("g", "Bash", "rm -rf build", outcome: .denied, gist: "cleaned"))!
        XCTAssertEqual([denied.verb, denied.object, denied.gist, denied.result], ["Didn't run", "rm -rf build", "", "you said no"])
        XCTAssertEqual(StepLine.of(step("g", "Bash", "cargo test", outcome: nil, gist: "x"))?.gist, "", "a running step has no gist")
    }

    /// A test run reads "10 of 11" from the engine's `tests`, with the time; never parsed from
    /// output. The same output without `tests` is a plain command.
    func testATestRunReadsTheEnginesCount() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let tests = Item.TestRun(runner: "cargo", passed: 10, failed: 1, total: 11, failedNames: ["upload_retries_on_503"])
        let out = "test result: FAILED. 10 passed; 1 failed; 0 ignored"
        let run = StepLine.of(step("t", "Bash", "cargo test -q upload", outcome: .error, output: out, tests: tests,
                                   started: t0, ended: t0.addingTimeInterval(9)))!
        XCTAssertEqual(run.text, "Failed cargo test -q upload 10 of 11 · 9.0s")
        let plain = StepLine.of(step("t", "Bash", "cargo test -q upload", outcome: .error, output: out))!
        XCTAssertEqual(plain.result, "", "no `tests`: a plain command, whatever the output says")
        XCTAssertEqual(StepLine.of(step("t", "Bash", "cargo test", tests: Item.TestRun(runner: "cargo", passed: 11, failed: 0, total: 11),
                                        started: t0, ended: t0.addingTimeInterval(14)))?.result, "11 of 11 · 14s")
    }

    /// Results are the engine's display without the verb it repeats; an edit's counts are its own.
    func testResultsAtTheRight() {
        XCTAssertEqual(StepLine.of(step("r", "Read", "src/retry.rs", display: "Read 124 lines"))?.text, "Read src/retry.rs 124 lines")
        XCTAssertEqual(StepLine.of(step("g", "Grep", "thread_rng", display: "3 matches in 2 files"))?.text, "Searched thread_rng 3 matches in 2 files")
        let diff = FileDiff(path: "src/retry.rs", created: false, added: 3, removed: 2, hunks: [])
        let edit = StepLine.of(step("e", "Edit", "src/retry.rs", diff: diff))!
        XCTAssertEqual(edit.text, "Edited src/retry.rs +3 −2")
        XCTAssertEqual(edit.result, "")
        XCTAssertEqual(StepLine.duration(2.2), "2.2s")
        XCTAssertEqual(StepLine.duration(14.4), "14s")
        XCTAssertEqual(StepLine.duration(125), "2m 5s")
    }

    /// Four or more finished steps fold into "N steps" and the time; a failed step never folds
    /// and splits the run; a running step breaks it.
    func testFolds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func read(_ i: Int) -> ItemState {
            step("r\(i)", "Read", "f\(i)", started: t0.addingTimeInterval(Double(i) * 0.6), ended: t0.addingTimeInterval(Double(i) * 0.6 + 0.4))
        }
        let four = (0..<4).map(read)
        let runs = StepRuns.of(four)
        XCTAssertEqual(runs.count, 1)
        guard case .fold(let steps) = runs.first else { return XCTFail("four steps fold") }
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(StepRuns.time(steps), "2.2s")
        XCTAssertEqual(StepRuns.of(Array(four.prefix(3))).count, 3, "three stay lines")
        let failed = step("x", "Bash", "cargo test", outcome: .error)
        let split = StepRuns.of(Array(four.prefix(2)) + [failed] + Array(four.suffix(2)))
        XCTAssertEqual(split.map(\.id), ["r0", "r1", "x", "r2", "r3"], "a failed step never folds, and splits the run")
        let fiveWithFailure = StepRuns.of(four + [failed])
        XCTAssertEqual(fiveWithFailure.map(\.id), ["fold-r0", "x"])
        XCTAssertEqual(StepRuns.of(Array(four.prefix(2)) + [step("y", "Bash", "sleep 9", outcome: nil)] + Array(four.suffix(2))).count, 4,
                       "a running step breaks the run")
    }

    /// A failed command opens itself once, then stays as the person left it.
    @MainActor
    func testAFailedCommandOpensItselfOnce() {
        SelfOpening.reset()
        let failed = StepLine.of(step("f1", "Bash", "cargo test", outcome: .error))!
        XCTAssertTrue(SelfOpening.opens("f1", failed))
        SelfOpening.remember("f1", open: false)
        XCTAssertFalse(SelfOpening.opens("f1", failed), "closed by the person: stays closed across remounts")
        XCTAssertFalse(SelfOpening.opens("r1", StepLine.of(step("r1", "Read", "a", outcome: .error))!), "only commands open themselves")
        XCTAssertFalse(SelfOpening.opens("ok", StepLine.of(step("ok", "Bash", "ls"))!))
    }

    /// The left edge: a mark hangs 26 into a 32 gutter; under 480 the gutter is 16 and text
    /// indents by 26 instead.
    func testTheLeftEdge() {
        XCTAssertEqual(TranscriptEdge.of(paneWidth: 1010), TranscriptEdge(gutter: 32, indent: 0))
        XCTAssertEqual(TranscriptEdge.of(paneWidth: 479), TranscriptEdge(gutter: 16, indent: 26))
    }

    func testDiagnosticNoticesStayOutOfTheComposer() {
        XCTAssertNil(Conversation.plainNotice("context window: 32768 tokens (from server); auto-compacting past 27852"))
        XCTAssertNil(Conversation.plainNotice("repo map limited to 20,000 files or 2 seconds"))
        XCTAssertEqual(Conversation.plainNotice("started a new conversation"), "Started a new conversation")
        XCTAssertNotNil(Conversation.plainNotice("Network allow-list: pypi.org allowed for the rest of this session."))
        // First-run audit: retries and Frog Cloud's stand-in went only to the log.
        XCTAssertEqual(Conversation.plainNotice("Frog Cloud is busy — retrying"), "Frog Cloud is busy — retrying")
        let standIn = "Frog Cloud: GLM-5.3 Flash is still busy, so DeepSeek V4.1 Flash is answering for now. The session's model hasn't changed."
        XCTAssertEqual(Conversation.plainNotice(standIn), standIn)
    }

    /// The permission card says where the step runs: a Frog Cloud session's card said "this Mac".
    func testPermissionCardSaysWhereItRuns() {
        XCTAssertEqual(PermissionRequest.runsWhere(inCloud: false, outsideSandbox: false), "Runs on this Mac · sandboxed")
        XCTAssertEqual(PermissionRequest.runsWhere(inCloud: false, outsideSandbox: true), "Runs on this Mac · outside the sandbox")
        XCTAssertEqual(PermissionRequest.runsWhere(inCloud: true, outsideSandbox: false), "Runs in your Frog Cloud sandbox")
    }

    func testThePickerLeavesOutSideJobHelpers() {
        XCTAssertTrue(ModelMenu.sideJobHelper("cloud/qwen3-8b"))
        XCTAssertTrue(ModelMenu.sideJobHelper("cloud/qwen3-vl-8b"))
        XCTAssertFalse(ModelMenu.sideJobHelper("cloud/qwen3-coder-next"))
        XCTAssertFalse(ModelMenu.sideJobHelper("cloud/deepseek-v4.1-flash"))
        XCTAssertFalse(ModelMenu.sideJobHelper("cloud/qwen3-32b"))
    }

    func testDownloadSizesReadAsSettingsWritesThem() {
        XCTAssertEqual(SuggestedModel.gbText(18.0), "18 GB")
        XCTAssertEqual(SuggestedModel.gbText(4.6), "4.6 GB")
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

    /// "frog manager" (2026-11-14): forty rows read `cd /Users/cam/Developer/frog && …` with
    /// the meaning truncated off the end. The command leads; a worktree shows by name; the
    /// full command stays the row's help.
    func testACdPrefixGivesWayToTheCommand() {
        var root = ItemState(id: "c1", kind: .tool(name: "Bash", arg: "cd /Users/cam/Developer/frog && git log --oneline -2"))
        root.done = true
        let r = StepLine.of(root)!
        XCTAssertEqual(r.object, "git log --oneline -2")
        XCTAssertEqual(r.result, "", "the session root on every row is noise")
        XCTAssertEqual(r.title, "cd /Users/cam/Developer/frog && git log --oneline -2")

        var wt = ItemState(id: "c2", kind: .tool(name: "Bash", arg: "cd \"/Users/cam/Developer/frog/.frog/worktrees/audit334\" && timeout 600 cargo test -p frog-engine"))
        wt.done = true
        let w = StepLine.of(wt)!
        XCTAssertEqual(w.object, "timeout 600 cargo test -p frog-engine")
        XCTAssertEqual(w.result, "in audit334")

        // Not that shape: whole.
        XCTAssertEqual(StepLine.splitCd("cd foo").command, "cd foo")
        XCTAssertEqual(StepLine.splitCd("cd a || b").command, "cd a || b")
        XCTAssertEqual(StepLine.splitCd("git status").command, "git status")
    }
}

import Foundation
import XCTest
@testable import Frog

/// A turn reads in the order it happened, with each run of steps summed up in one sentence.
final class TurnFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func tool(_ id: String, _ name: String, _ arg: String, outcome: ToolOutcome = .ok,
                      diff: FileDiff? = nil, done: Bool = true) -> ItemState {
        var item = ItemState(id: id, kind: .tool(name: name, arg: arg))
        item.done = done
        if done {
            item.result = Item.ToolResult(name: name, arg: arg, input: nil, outcome: outcome, output: "", display: nil, diff: diff)
        }
        return item
    }

    private func message(_ id: String, _ text: String) -> ItemState {
        ItemState(id: id, kind: .message, text: text, done: true)
    }

    private func thought(_ id: String, _ text: String, secs: TimeInterval? = nil, done: Bool = true) -> ItemState {
        var item = ItemState(id: id, kind: .reasoning, text: text, done: done)
        if let secs {
            item.startedAt = t0
            item.endedAt = t0.addingTimeInterval(secs)
        }
        return item
    }

    private func diff(_ path: String, _ added: UInt32, _ removed: UInt32, created: Bool = false) -> FileDiff {
        FileDiff(path: path, created: created, added: added, removed: removed, hunks: [])
    }

    private func sentence(_ steps: [ItemState]) -> String {
        ActivityWords.plain(ActivityWords.summary(steps))
    }

    /// Summary of each segment: text as "text: …", groups as their sentence.
    private func outline(_ flow: TurnFlow) -> [String] {
        flow.segments.map { s in
            switch s {
            case .text(let i): "text: \(i.text)"
            case .activity(let g): ActivityWords.plain(g.summary)
            case .visual(let i): "visual: \(i.id)"
            case .notice(let i): "notice: \(i.text)"
            }
        }
    }

    // MARK: Grouping

    func testSegmentsAreChronological() {
        let long = String(repeating: "Weigh the options. ", count: 20)
        let flow = TurnFlow([
            message("m1", "Let me look."),
            tool("a", "Read", "Frog/Views/PaneView.swift"),
            tool("b", "Read", "Frog/Views/Sidebar.swift"),
            tool("c", "Grep", ".id("),
            message("m2", "Found it."),
            thought("r", long, secs: 4),
            tool("d", "Edit", "Sidebar.swift", diff: diff("Sidebar.swift", 3, 1)),
            tool("e", "Bash", "xcodebuild test"),
            message("m3", "Fixed."),
        ])
        XCTAssertEqual(outline(flow), [
            "text: Let me look.",
            "Read 2 files, searched for “.id(”",
            "text: Found it.",
            "Thought for 4s",
            "Edited Sidebar.swift +3 −1, ran the tests",
            "text: Fixed.",
        ])
    }

    func testShortThoughtFoldsIntoTheNextLine() {
        let flow = TurnFlow([
            thought("r", "Check the sidebar first.", secs: 1),
            tool("a", "Read", "a.swift"),
            tool("b", "Read", "b.swift"),
            tool("c", "Read", "c.swift"),
            message("m", "Done."),
        ])
        XCTAssertEqual(outline(flow), ["Thought, then read 3 files", "text: Done."])
    }

    /// A model's scratch line before answering (Apple Intelligence writes one every turn)
    /// isn't worth a line: the answer stands alone.
    func testShortThoughtAloneIsLeftOut() {
        let flow = TurnFlow([thought("r", "Easy one.", secs: 0.4), message("m", "Hi.")])
        XCTAssertEqual(outline(flow), ["text: Hi."])
    }

    func testLongThoughtWithNothingAfterIsOneLine() {
        let flow = TurnFlow([thought("r", String(repeating: "x", count: 400), secs: 95), message("m", "Answer.")])
        XCTAssertEqual(outline(flow), ["Thought for 1m 35s", "text: Answer."])
    }

    func testThinkingHiddenBySetting() {
        let flow = TurnFlow([thought("r", "Hmm.", secs: 2), message("m", "Answer.")], showThinking: false)
        XCTAssertEqual(outline(flow), ["text: Answer."])
    }

    func testEmptyMessageDoesNotSplitAGroup() {
        let flow = TurnFlow([
            tool("a", "Read", "a.swift"),
            ItemState(id: "m", kind: .message, text: "  "),
            tool("b", "Read", "b.swift"),
        ])
        XCTAssertEqual(outline(flow), ["Read 2 files"])
    }

    func testNoticesAndDiagramsBreakGroups() {
        var diagram = tool("d", "Diagram", "Flow", done: false)
        diagram.done = false
        let flow = TurnFlow([
            tool("a", "Read", "a.swift"),
            ItemState(id: "n", kind: .notice(warning: true), text: "Careful", done: true),
            tool("b", "Read", "b.swift"),
            diagram,
        ])
        XCTAssertEqual(outline(flow), ["Read a.swift", "notice: Careful", "Read b.swift", "visual: d"])
    }

    // MARK: Sentences

    func testSentences() {
        XCTAssertEqual(sentence([tool("a", "Read", "src/PaneView.swift")]), "Read PaneView.swift")
        XCTAssertEqual(sentence([tool("a", "Read", "x.swift"), tool("b", "Read", "x.swift")]), "Read x.swift")
        XCTAssertEqual(sentence([tool("a", "Bash", "ls -la")]), "Ran a command")
        XCTAssertEqual(sentence([tool("a", "Bash", "ls"), tool("b", "Bash", "pwd")]), "Ran 2 commands")
        XCTAssertEqual(sentence([tool("a", "Grep", "foo"), tool("b", "Glob", "*.py")]), "Searched for “foo” and “*.py”")
        XCTAssertEqual(sentence([tool("a", "Grep", "a"), tool("b", "Grep", "b"), tool("c", "Grep", "c")]), "Searched 3 times")
        XCTAssertEqual(sentence([
            tool("a", "Edit", "a.swift", diff: diff("a.swift", 10, 4)),
            tool("b", "Edit", "b.swift", diff: diff("b.swift", 8, 2)),
            tool("c", "Bash", "swift test"),
        ]), "Edited 2 files +18 −6, ran the tests")
        XCTAssertEqual(sentence([tool("a", "Write", "new.py", diff: diff("new.py", 12, 0, created: true))]), "Created new.py +12 −0")
        XCTAssertEqual(sentence([tool("a", "mcp__github__list_issues", "")]), "Used github")
        XCTAssertEqual(sentence([tool("a", "WebFetch", "https://example.com/docs")]), "Fetched example.com")
    }

    func testFailuresAreCounted() {
        XCTAssertEqual(sentence([
            tool("a", "Edit", "main.py", diff: diff("main.py", 1, 1)),
            tool("b", "Edit", "report.py", outcome: .error),
            tool("c", "Bash", "python3 main.py"),
        ]), "Edited main.py +1 −1, ran a command, 1 failed")
        // An edit that never landed isn't "edited".
        XCTAssertEqual(sentence([tool("a", "Edit", "main.py", outcome: .error)]), "1 failed")
    }

    func testRunningStepsAreNotInTheSentenceYet() {
        let group = ActivityGroup(steps: [tool("a", "Read", "a.swift"), tool("b", "Bash", "make test", done: false)])
        XCTAssertEqual(ActivityWords.plain(group.summary), "Read a.swift")
        XCTAssertEqual(group.current.map(ActivityWords.now), "Running the tests…")
    }

    func testRowsAndLiveWords() {
        XCTAssertEqual(ActivityWords.row(tool("a", "Read", "Frog/Views/PaneView.swift")), "Read PaneView.swift")
        XCTAssertEqual(ActivityWords.row(tool("a", "Bash", "xcodebuild test")), "Ran xcodebuild test")
        XCTAssertEqual(ActivityWords.row(thought("r", "x", secs: 2)), "Thought for 2s")
        XCTAssertEqual(ActivityWords.now(tool("a", "Read", "Frog/Views/Sidebar.swift", done: false)), "Reading Sidebar.swift…")
        XCTAssertEqual(ActivityWords.now(thought("r", "x", done: false)), "Thinking…")
    }

    // MARK: Footers

    @MainActor
    func testFooterPinsLatestModelChangesAndCost() {
        func turn(_ model: String?) -> TurnState {
            var t = TurnState(number: 1, input: "hi", end: .complete)
            t.usage = TurnUsage(contextTokens: nil, inputTokens: 10, outputTokens: 10, modelCalls: 1, tokensPerSec: nil, model: model)
            return t
        }
        let turns = [turn("a"), turn("a"), turn("b"), turn("b"), turn("cloud"), turn("cloud")]
        let pinned = TurnFooter.pinned(turns) { $0.model == "cloud" ? 0.01 : nil }
        XCTAssertEqual(turns.map { pinned.contains($0.id) }, [false, false, true, false, true, true])
    }
}

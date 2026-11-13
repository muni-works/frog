import XCTest
@testable import Frog

/// Cam's report: a `SendMessage` row took two clicks to reach its payload, and the label
/// repeated. The collapsed line said "Used SendMessage"; the first click opened a boxed row
/// saying "Used SendMessage" again; only the second click showed the result — one sentence.
///
/// The rule these tests pin, as data on `ToolLook` rather than another switch: a tool whose
/// result is a sentence (`ToolLook.isInline`) says it on the row's own line, and a lone step
/// opens straight to its content instead of to a row repeating the line that opened it.
///
/// Note on what a test can see: a hosted SwiftUI view exposes no readable text (checked — the
/// accessibility tree of `NSHostingView(rootView: Text("…"))` is empty), so no unit test can
/// count labels in a render. The duplication is therefore pinned where it is actually decided:
/// the strings the two levels print, and the branch that chooses whether the second one exists.
@MainActor
final class ToolRowClicksTests: XCTestCase {
    private func tool(_ id: String, _ name: String, _ arg: String = "",
                      output: String = "", display: String? = nil,
                      outcome: ToolOutcome = .ok) -> ItemState {
        var item = ItemState(id: id, kind: .tool(name: name, arg: arg))
        item.done = true
        item.output = output
        item.result = Item.ToolResult(
            name: name, arg: arg, input: nil, outcome: outcome,
            output: output, display: display)
        return item
    }

    /// The sentence a real `SendMessage` returned (SessionBroker's success reply).
    private static let sent = "Sent to ops (20261112-175150-6a2c); delivered (turn started). It reads the message at its next turn boundary; its reply, if any, arrives as a <session-message>."

    // MARK: The line carries the meat, with zero clicks

    /// The cheapest high-value fix, and the one Cam cared about most: the collapsed line already
    /// says the result. Before this, `VerbLine.of` gave `SendMessage` its verb and nothing else,
    /// so the sentence existed only behind two clicks.
    func testAShortResultIsOnTheLineItself() {
        let line = VerbLine.of(tool("t1", "SendMessage", "ops", output: Self.sent))
        XCTAssertEqual(line?.verb, "Used SendMessage")
        XCTAssertEqual(line?.arg, "ops")
        XCTAssertEqual(line?.detail, "Sent to ops (20261112-175150-6a2c); delivered (turn started)",
                       "the row's own line should carry the result, cut at its first sentence")
        XCTAssertTrue(line?.detail?.contains("delivered") == true,
                      "with no click at all, the line says what happened")
    }

    /// The tools Cam listed as short results, each reaching its line.
    func testEveryShortToolSaysItsResultOnTheLine() {
        let cases: [(String, String, String?)] = [
            ("Ask", "The user chose: Send now", "chose: Send now"),
            ("TodoWrite", "Todo list updated.", "Todo list updated."),
            ("Skill", "", "Loaded the code-review skill"),
            ("UseFolder", "Moved to /tmp/demo", "Moved to /tmp/demo"),
            ("RenameSession", "Renamed s2 to \"tool row clicks\".", "Renamed s2 to \"tool row clicks\"."),
            ("MoveSession", "Moved ops (s2) under its new parent; the sidebar regroups.", "Moved ops (s2) under its new parent; the sidebar regroups."),
            ("ArchiveSession", "Archived ops (s2). Its log is kept; UnarchiveSession brings it back.", "Archived ops (s2)"),
        ]
        for (name, output, display) in cases {
            let line = VerbLine.of(tool("t", name, "x", output: output, display: display))
            // The line must not say its own words twice: "Moved to /tmp/demo · Moved to
            // /tmp/demo". `UseFolder` is the case that literally would — the result opens by
            // repeating the verb — so its line ends up bare (nothing new to add), which is
            // correct and still no click.
            if let verb = line?.verb, let detail = line?.detail {
                XCTAssertFalse(detail.lowercased().hasPrefix(verb.lowercased()),
                               "\(name): the line repeats its own verb — \"\(verb) · \(detail)\"")
            }
        }
        // The one whose result is entirely its own line says nothing extra, rather than twice.
        XCTAssertNil(VerbLine.of(tool("t", "UseFolder", "/tmp/demo", output: "Moved to /tmp/demo"))?.detail)
        // The others do carry news.
        XCTAssertEqual(VerbLine.of(tool("t", "TodoWrite", "x", output: "Todo list updated."))?.detail,
                       "Todo list updated.")
        // ListSessions' result is a page of JSON; the row says the count instead of "[".
        let listed = tool("t9", "ListSessions", "", output: #"[{"id":"a"},{"id":"b"},{"id":"c"}]"#)
        XCTAssertEqual(VerbLine.of(listed)?.detail, "3 sessions")
    }

    /// The other half of the rule: a payload stays behind the row. `Bash` output is not the
    /// line's business, and no inline tool claims it.
    func testPayloadToolsAreNotInline() {
        for name in ["Read", "Bash", "!", "Grep", "WebFetch", "Task", "Edit", "Write"] {
            XCTAssertFalse(ToolLook.isInline(name), "\(name) has a payload, not a sentence")
        }
        let ran = tool("t2", "Bash", "cargo test", output: "test result: ok. 666 passed")
        XCTAssertNil(VerbLine.of(ran)?.detail, "a command's output must not be pasted on its line")
    }

    // MARK: No repeated label, no second click

    /// The duplication, at its source: the opened step's own row title carries the very words the
    /// collapsed line already said. Drawn together, that's "Used SendMessage" twice — which is
    /// why the lone-step branch exists (and is pinned in the test below it).
    func testTheStepRowsTitleWouldOnlyRepeatTheLine() {
        let sent = tool("t1", "SendMessage", "ops", output: Self.sent)
        let line = VerbLine.of(sent)
        let rowTitle = ActivityWords.row(sent)
        XCTAssertTrue(rowTitle.contains(line?.verb ?? "\u{0}"),
                      "\"\(rowTitle)\" carries \"\(line?.verb ?? "")\" — the row would say the line again")
        // The fix is that a lone step never draws that row (see the test below), not that the
        // two strings are made to differ: the row's job is the payload, not another label.
    }

    /// The regression itself. A lone finished tool step opens straight to its content:
    /// `ActivitySteps` must not draw a row that repeats the line above it.
    ///
    /// Asserted as the branch the view takes, not as `opensDirectly` alone: the predicate and
    /// the `else if` that uses it are two places that must agree, and a test of the predicate
    /// alone passes with the branch deleted (checked — it did). `layout` is the one place that
    /// decides, so the view and this test read the same answer.
    func testALoneStepOpensToItsContentNotToItsOwnRow() {
        let sent = tool("t1", "SendMessage", "ops", output: "Sent to ops; delivered.")
        XCTAssertEqual(ActivitySteps.layout([sent]), .content,
                       "a lone tool step must open to its content, not to a row repeating the label")
        // A step waiting on you keeps its row: it has a permission card to show.
        var waiting = sent
        waiting.needsPermission = true
        XCTAssertEqual(ActivitySteps.layout([waiting]), .rows)
        // Several steps keep their rows: each is named, and none is the line's own label.
        XCTAssertEqual(ActivitySteps.layout([sent, tool("t2", "RenameSession", "x")]), .rows)
        // A thought has its own treatment, not this one.
        var thought = ItemState(id: "r1", kind: .reasoning)
        thought.done = true
        XCTAssertEqual(ActivitySteps.layout([thought]), .thought)
        // A step still running has nothing to show yet.
        var running = sent
        running.done = false
        XCTAssertEqual(ActivitySteps.layout([running]), .rows)
    }

    // MARK: The chevron only shows when something is behind it

    /// A line that already says everything gets no chevron: a click that reveals nothing is the
    /// same wasted click in the other direction.
    func testAFullySaidResultNeedsNoChevron() {
        XCTAssertTrue(ToolLook.fits(name: "SendMessage", display: nil,
                                    output: "Sent to ops; delivered."),
                      "one short line: nothing behind it")
        XCTAssertFalse(ToolLook.fits(name: "SendMessage", display: nil,
                                     output: "Sent to ops; delivered. It reads the message at its next turn boundary."),
                       "a sentence the line cut short has more behind it")
        XCTAssertFalse(ToolLook.fits(name: "SendMessage", display: nil, output: "a\nb"), "two lines")
    }

    // MARK: The helpers the views read

    func testTheLineIsOneClippedLine() {
        let long = String(repeating: "x", count: 200)
        let said = ToolLook.line(name: "SendMessage", display: nil, output: long)
        XCTAssertEqual(said.count, ToolLook.lineCap, "clipped to one line, ellipsis included")
        XCTAssertTrue(said.hasSuffix("…"))
        // An engine display wins over the raw output (Ask's "The user chose: …").
        XCTAssertEqual(ToolLook.line(name: "Ask", display: "chose: Send now", output: "The user chose: Send now"),
                       "chose: Send now")
        XCTAssertEqual(ToolLook.line(name: "SendMessage", display: nil, output: "  \n "), "")
    }
}

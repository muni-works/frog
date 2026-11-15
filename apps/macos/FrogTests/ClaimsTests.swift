import Foundation
import XCTest
@testable import Frog

/// The outcome card's parser (review-ux step 2): a worker ends its turn with a `claims:` block
/// (the step-1 convention), each claim with the command that checks it. Read-only: everything
/// parsed is pending — the worker's say-so — until step 4 runs the checks.
final class ClaimsTests: XCTestCase {
    // MARK: the convention's shapes

    func testWellFormedBlock() {
        let claims = Claims.parse("""
        Fixed the sign-in flow.

        claims:
        - sign-in works on staging — verify: curl -s https://staging/signin | grep ok
        - existing api keys still work (verify: cargo test -p api keys)
        """)
        XCTAssertEqual(claims?.count, 2)
        XCTAssertEqual(claims?[0].text, "sign-in works on staging")
        XCTAssertEqual(claims?[0].check, "curl -s https://staging/signin | grep ok")
        XCTAssertEqual(claims?[0].state, .pending)
        XCTAssertEqual(claims?[1].text, "existing api keys still work")
        XCTAssertEqual(claims?[1].check, "cargo test -p api keys")
    }

    func testOpenersAndNumberedLists() {
        for head in ["claims:", "claims", "Claims:", "**claims**", "### Claims:"] {
            let claims = Claims.parse("\(head)\n- tests pass")
            XCTAssertEqual(claims?.map(\.text), ["tests pass"], head)
        }
        let numbered = Claims.parse("claims:\n1. the app builds\n2. no cards shown")
        XCTAssertEqual(numbered?.map(\.text), ["the app builds", "no cards shown"])
    }

    func testFieldLinesAttachToTheClaimAbove() {
        let claims = Claims.parse("""
        claims:
        - the app opens
          verify: open -a Frog
        - it runs clean
          evidence: 12 passed
        """)
        XCTAssertEqual(claims?.count, 2)
        XCTAssertEqual(claims?[0].text, "the app opens")
        XCTAssertEqual(claims?[0].check, "open -a Frog")
        XCTAssertEqual(claims?[1].text, "it runs clean")
        XCTAssertEqual(claims?[1].evidence, "12 passed")
        XCTAssertNil(claims?[1].check)
    }

    func testBareDashWithACommand() {
        let claims = Claims.parse("claims:\n- tests pass — cargo test -p frog")
        XCTAssertEqual(claims?[0].text, "tests pass")
        XCTAssertEqual(claims?[0].check, "cargo test -p frog")
    }

    func testProseDashStaysProse() {
        let claims = Claims.parse("claims:\n- the fix holds — and it costs nothing")
        XCTAssertEqual(claims?[0].text, "the fix holds — and it costs nothing")
        XCTAssertNil(claims?[0].check)
    }

    func testDoubleColonCheck() {
        let claims = Claims.parse("claims:\n- no regressions :: swift test")
        XCTAssertEqual(claims?[0].check, "swift test")
    }

    func testClaimsInsideFencedCodeAreNotClaims() {
        let message = """
        here's the convention:

        ```
        claims:
        - this is an example, not a claim
        ```
        """
        XCTAssertNil(Claims.parse(message))
    }

    // MARK: the tolerant failures

    func testNoBlockIsNil() {
        XCTAssertNil(Claims.parse("done, tests pass."))
        XCTAssertNil(Claims.parse(""))
        XCTAssertNil(Claims.parse("I mentioned claims: in prose but never listed any."))
    }

    func testMalformedBlockIsNil() {
        // Opens, but the first line after it is prose: the block never gets going.
        XCTAssertNil(Claims.parse("claims:\nThe changes are all in main.rs."))
        // A claims block with nothing readable in it isn't a card.
        XCTAssertNil(Claims.parse("claims:\n\n—"))
    }

    func testClaimWithoutACheckStillCounts() {
        let claims = Claims.parse("claims:\n- the sidebar reads calmer")
        XCTAssertEqual(claims?.map(\.text), ["the sidebar reads calmer"])
        XCTAssertNil(claims?[0].check)
        XCTAssertEqual(claims?[0].state, .pending)
    }

    func testMultipleClaimKinds() {
        let claims = Claims.parse("""
        claims:
        - engine builds — cargo build -p frog
        - the flag is off
          evidence: FeatureFlags.outcomeCard == false
        - open: does the card fold?
        """)
        XCTAssertEqual(claims?.count, 3)
        XCTAssertEqual(claims?[0].check, "cargo build -p frog")
        XCTAssertEqual(claims?[1].evidence, "FeatureFlags.outcomeCard == false")
        XCTAssertNil(claims?[1].check)
        XCTAssertEqual(claims?[2].text, "open: does the card fold?")
    }

    func testBlockEndsAtProse() {
        let claims = Claims.parse("""
        claims:
        - tests pass
        — verify: cargo test
        """)
        // A prose-dash line ends the block, so the second line isn't read as a claim.
        XCTAssertEqual(claims?.map(\.text), ["tests pass"])
    }

    // MARK: from a turn

    func testFromTurnReadsTheLastFinishedMessage() throws {
        // The card is behind the flag (step 2 ships dark): with the flag off the turn says nil.
        try XCTSkipUnless(FeatureFlags.outcomeCard, "the on-state only holds with the flag on")
        let earlier = ItemState(id: "m1", kind: .message, text: "half done", done: true)
        let answer = ItemState(id: "m2", kind: .message,
                               text: "Fixed it.\n\nclaims:\n- it builds — cargo build", done: true)
        var turn = TurnState(input: "fix", items: [earlier, answer])
        turn.end = .complete
        XCTAssertEqual(turn.claims?.map(\.text), ["it builds"])
        XCTAssertEqual(turn.claims?[0].check, "cargo build")
    }

    func testParserReadsTheLastFinishedMessageRegardlessOfFlag() {
        // The parser itself is flag-independent (the card's gate is in the views).
        let turn = TurnState(input: "fix", items: [ItemState(id: "m", kind: .message,
                               text: "Fixed it.\n\nclaims:\n- it builds — cargo build", done: true)])
        XCTAssertEqual(Claims.fromTurn(turn)?.map(\.text), ["it builds"])
    }

    func testFromTurnNilWithoutClaims() {
        let turn = TurnState(input: "hi", items: [ItemState(id: "m", kind: .message, text: "nothing to claim", done: true)])
        XCTAssertNil(Claims.fromTurn(turn))
    }

    // MARK: subagent reports

    func testSubagentReportClaims() {
        // The parser over a report's messages (the card's flag gate lives in the views).
        var run = SubagentRun()
        run.apply(.itemCompleted(id: "r", item: .message("the audit is done.\n\nclaims:\n- no secrets in logs — grep -r sk- .")))
        XCTAssertEqual(Claims.parse(run.items.last?.text ?? "")?.map(\.text), ["no secrets in logs"])
        XCTAssertEqual(Claims.parse(run.items.last?.text ?? "")?[0].check, "grep -r sk- .")
    }

    // MARK: read-only

    func testEveryParsedClaimIsPending() {
        // The card is read-only until step 4: parsing never marks a claim passed or failed,
        // however sure the worker sounds.
        let claims = Claims.parse("claims:\n- definitely verified: cargo test\n- passed all the tests")
        XCTAssertEqual(claims?.allSatisfy { $0.state == .pending }, true)
    }
}

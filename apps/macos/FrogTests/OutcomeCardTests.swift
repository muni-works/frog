import SwiftUI
import XCTest
@testable import Frog

/// The outcome card's rendering (review-ux step 2): a checklist of claims in place of (or below)
/// the changes strip, one row per claim — glyph, text, the check in quiet mono — and the footer
/// that points to the Changes tab. Read-only: no buttons, no diffs, nothing but what the worker
/// claimed. Hidden entirely when the flag is off.
@MainActor
final class OutcomeCardTests: XCTestCase {
    private func card(_ claims: [Claim]) -> OutcomeCard {
        OutcomeCard(claims: claims)
    }

    // MARK: rows per state

    func testGlyphsPerState() {
        // Pending is the quiet dotted dot; a verified claim is the accent's check; a failed
        // one is the xmark. State color lives on the glyph only (Tokens' rule).
        XCTAssertEqual(OutcomeCard.glyph(.pending), "circle.dotted")
        XCTAssertEqual(OutcomeCard.glyph(.passed), "checkmark")
        XCTAssertEqual(OutcomeCard.glyph(.failed), "xmark")
    }

    func testStateColorsComeFromTheTokens() {
        // Resolved against the dark appearance: signal amber to wait, accent green to pass,
        // fail red to fail (the premium tokens' state ramp).
        XCTAssertEqual(OutcomeCard.color(.pending), Tokens.signal)
        XCTAssertEqual(OutcomeCard.color(.passed), Tokens.accent)
        XCTAssertEqual(OutcomeCard.color(.failed), Tokens.fail)
    }

    func testCardBodyRendersACheckRowAndTheFooter() {
        let body = String(describing: card([Claim(text: "the app opens", check: "open -a Frog")]).body)
        XCTAssertTrue(body.contains("the app opens"))
        XCTAssertTrue(body.contains("open -a Frog"))
        XCTAssertTrue(body.contains("Changes tab"), "the footer names the way to the diffs")
    }

    func testFooterCountsAndPointsToTheChangesTab() {
        XCTAssertEqual(OutcomeCard.footer(1), "1 claim · diffs in the Changes tab")
        XCTAssertEqual(OutcomeCard.footer(2), "2 claims · diffs in the Changes tab")
        XCTAssertEqual(OutcomeCard.footer(12), "12 claims · diffs in the Changes tab")
    }

    // MARK: the flag gates the card

    func testFlagOffTurnShowsNoClaims() throws {
        // Off: the turn extension returns nil, so the tail renders the strip exactly as before.
        try XCTSkipIf(FeatureFlags.outcomeCard, "the off-state only holds with the flag off")
        var turn = TurnState(input: "go", items: [ItemState(id: "m", kind: .message, text: "claims:\n- done", done: true)])
        turn.end = .complete
        XCTAssertNil(turn.claims)
    }

    func testFlagOffSubagentShowsNoClaims() throws {
        try XCTSkipIf(FeatureFlags.outcomeCard, "the off-state only holds with the flag off")
        var run = SubagentRun()
        run.apply(.itemCompleted(id: "r", item: .message("claims:\n- done — cargo test")))
        XCTAssertNil(run.claims)
    }

    func testFlagOffTurnKeepsItsChangesStrip() {
        // Off: TurnParts is untouched — the card never removes the strip's data.
        let diff = FileDiff(path: "a.swift", created: false, added: 3, removed: 1, hunks: [])
        var item = ItemState(id: "e", kind: .tool(name: "Edit", arg: "a.swift"), done: true)
        item.result = Item.ToolResult(name: "Edit", arg: "a.swift", input: nil, outcome: .ok, output: "", display: nil, diff: diff)
        let turn = TurnState(input: "go", items: [item])
        XCTAssertEqual(TurnParts(turn).changes.count, 1)
        XCTAssertNil(turn.claims)
    }
}

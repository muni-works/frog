import XCTest
@testable import Frog

/// What frog found on this Mac, as the first-run line uses it (docs/onboarding.md).
@MainActor
final class OnboardingTests: XCTestCase {
    func testSetupReportLoadsFromFrog() async throws {
        let r = try await Frog.json(SetupReport.self, args: ["--setup", "--json"], cwd: Frog.chatFolder)
        XCTAssertGreaterThanOrEqual(r.skills, 0)
    }

    func testSetupReportWords() {
        let r = SetupReport(instructions: ["/Users/x/.claude/CLAUDE.md"], skills: 56, rules: 0,
                            envKeys: ["Anthropic"], claudeMcp: ["fusion", "runpod"], claudeMcpOn: false)
        XCTAssertEqual(r.inUse, ["CLAUDE.md", "56 skills", "your Anthropic key"])
        XCTAssertEqual(r.toAdd, ["fusion", "runpod"])
        var on = r
        on.claudeMcpOn = true
        XCTAssertTrue(on.toAdd.isEmpty)
    }
}

/// The "bigger model" line shows when a small model is out of its depth, and only then.
final class BiggerModelTests: XCTestCase {
    private func turn(_ end: EndReason?) -> TurnState {
        var t = TurnState(number: 1, input: "fix the build")
        t.end = end
        return t
    }

    func testShowsWhenASmallModelIsOutOfItsDepth() {
        let overflow = EndReason.error(EngineError(type: "provider", status: nil, message: "Exceeded the context window size"))
        XCTAssertEqual(BiggerModelLine.reason(model: "Apple Intelligence", window: 8192, turns: [turn(overflow)], inProject: false),
                       "This conversation outgrew Apple Intelligence.")
        XCTAssertEqual(BiggerModelLine.reason(model: "Apple Intelligence", window: 8192, turns: [turn(.looping)], inProject: false),
                       "Apple Intelligence is struggling with this.")
        XCTAssertEqual(BiggerModelLine.reason(model: "Apple Intelligence", window: 8192, turns: [turn(.complete)], inProject: true),
                       "Apple Intelligence is small for work in a project.")
    }

    func testQuietOtherwise() {
        // A chat that went fine, a project before any turn, a big model that looped.
        XCTAssertNil(BiggerModelLine.reason(model: "Apple Intelligence", window: 8192, turns: [turn(.complete)], inProject: false))
        XCTAssertNil(BiggerModelLine.reason(model: "Apple Intelligence", window: 8192, turns: [], inProject: true))
        XCTAssertNil(BiggerModelLine.reason(model: "Qwen3 8B", window: 32_768, turns: [turn(.looping)], inProject: true))
    }
}

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

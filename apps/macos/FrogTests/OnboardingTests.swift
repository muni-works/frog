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

/// A project's greeting: what frog read, and where to start.
final class ProjectGlanceTests: XCTestCase {
    func testSummary() {
        var g = ProjectGlance(languages: ["Rust", "Swift"], lines: 41_230, changed: 3)
        XCTAssertEqual(g.summary, "Rust and Swift · 41k lines · 3 uncommitted changes")
        g = ProjectGlance(languages: ["Python"], lines: 420)
        XCTAssertEqual(g.summary, "Python · 420 lines")
        XCTAssertNil(ProjectGlance().summary)
    }

    func testStartsFollowTheState() {
        var g = ProjectGlance(changed: 2, lastCommit: "Engine: tidy", todo: (path: "src/engine.rs", text: "TODO: retry on 429"))
        XCTAssertEqual(g.starts.map(\.title), ["Review my changes", "The TODO in engine.rs", "How it fits together"])
        g = ProjectGlance(lastCommit: "Engine: tidy")
        XCTAssertEqual(g.starts.map(\.title), ["Pick up from the last commit", "How it fits together"])
    }

    /// Reads this repository: it's a git checkout with Rust and Swift in it.
    func testReadsARealRepository() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let g = try XCTUnwrap(ProjectGlance.read(root))
        XCTAssertTrue(g.languages.contains("Rust"), "\(g.languages)")
        XCTAssertGreaterThan(g.lines, 1000)
    }
}

import XCTest
@testable import Frog

/// Sidebar row state: how the listing's `end` (the last turn's reason) and the live tracking
/// fold into one glyph, and how RULES-prefixed prompts title.
final class SessionGlyphTests: XCTestCase {
    func testOpenTurnMeansRunning() {
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .open), .running)
    }

    func testAStaleOpenTurnIsIdleNotASpinner() {
        // An open turn from an engine that died hours ago: no spinner forever.
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .open, stale: true), .idle)
    }

    func testFailedTurnMeansFailed() {
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .failed), .failed)
    }

    func testLiveTrackingWins() {
        XCTAssertEqual(SessionEndGlyph.derive(live: .running, end: .complete), .running)
        XCTAssertEqual(SessionEndGlyph.derive(live: .running, end: .failed), .running)
        XCTAssertEqual(SessionEndGlyph.derive(live: .waiting, end: .failed), .waiting)
        XCTAssertEqual(SessionEndGlyph.derive(live: .unread, end: .failed), .unread)
    }

    func testCleanlyEndedSessionsIdle() {
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .complete), .idle)
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .stopped), .idle)
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: nil), .idle)
    }
}

/// Titles: a prompt's rules paragraph is skipped, so the row carries the task, not boilerplate.
final class SessionTitleTests: XCTestCase {
    func testRulesParagraphIsSkipped() {
        let prompt = """
        RULES: work ONLY inside /Users/cam/Developer/frog/.claude/worktrees/x (a git worktree). Never cd elsewhere.

        Build the thing.
        """
        XCTAssertEqual(SessionInfo.titleLine(prompt), "Build the thing.")
    }

    func testWholeRulesParagraphIsSkipped() {
        let prompt = """
        RULES: work ONLY inside /x (a git worktree).
        Keep command output small (| head -80).
        Commit on this branch.

        Now the actual task: fix the sidebar.
        """
        XCTAssertEqual(SessionInfo.titleLine(prompt), "Now the actual task: fix the sidebar.")
    }

    func testStoppedNoteIsSkipped() {
        let prompt = "You were stopped while running a command.\nFinish the sidebar work."
        XCTAssertEqual(SessionInfo.titleLine(prompt), "Finish the sidebar work.")
    }

    func testTitleUsesTheCleanedLine() {
        let json = #"{"id":"a","modified":1,"created":1,"model":"m","first_input":"RULES: stay in the worktree.\nAdd tests","cwd":"/tmp","end":"open"}"#
        let info = try! JSONDecoder.frog.decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.displayTitle, "Add tests")
        XCTAssertEqual(info.end, .open)
    }

    func testEndDecodesFromTheListing() throws {
        let json = #"{"id":"a","modified":1,"created":1,"model":"m","cwd":"/tmp","end":"failed"}"#
        let info = try JSONDecoder.frog.decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.end, .failed)
    }
}

/// A row's branch suffix: dropped when it only slugs the title, kept when it adds anything.
final class RowSuffixTests: XCTestCase {
    func testSluggedTitleHidesTheSuffix() {
        // Cam's screenshot: "sandbox pro…" next to "sandbo…l-docs" — both truncated.
        XCTAssertNil(RowSuffix.visible("sandbox-pro-docs", title: "sandbox pro"))
        XCTAssertNil(RowSuffix.visible("Sidebar_Status", title: "sidebar status"))
    }

    func testSuffixThatAddsSomethingStays() {
        XCTAssertEqual(RowSuffix.visible("feat/sidebar", title: "Add tests"), "feat/sidebar")
        XCTAssertEqual(RowSuffix.visible("frog-apple", title: "Thinking trace"), "frog-apple")
    }

    func testUnslugFoldsCaseAndSeparators() {
        XCTAssertEqual(RowSuffix.unslug("Sidebar-Status_v2 "), "sidebar status v2")
    }

    func testEmptyPiecesNeverShow() {
        XCTAssertNil(RowSuffix.visible(nil, title: "Anything"))
        XCTAssertNil(RowSuffix.visible("---", title: "Anything"))
    }
}

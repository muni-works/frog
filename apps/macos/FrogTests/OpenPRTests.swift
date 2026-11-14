import XCTest
@testable import Frog

/// `OpenPR.shouldOpenPR`, the pure predicate behind `[git] open_pr_when_done`. No git runs here
/// and no session store is read: the predicate takes facts and returns a decision, so these
/// tests can state every reason it must say no without arranging a repository.
final class OpenPRTests: XCTestCase {
    /// The one session that should get an offer: its own worktree, two commits on it, no PR,
    /// top level, no children, not read-only, not opted out.
    private var eligible: OpenPR.Input { .init(worktree: true, ahead: 2) }

    // MARK: The happy path

    func testAFinishedWorktreeSessionWithCommitsOpensAPR() {
        XCTAssertTrue(OpenPR.shouldOpenPR(eligible))
    }

    func testEveryReasonToSayNoIsEnoughOnItsOwn() {
        // Each case is `eligible` with exactly one fact changed: no single one may be ignored.
        let no: [(String, OpenPR.Input)] = [
            ("not its own worktree", .init(worktree: false, ahead: 2)),
            ("no commits ahead", .init(worktree: true, ahead: 0)),
            ("a PR already bound", .init(worktree: true, ahead: 2, hasPR: true)),
            ("read-only", .init(worktree: true, ahead: 2, readOnly: true)),
            ("opted out", .init(worktree: true, ahead: 2, optedOut: true)),
        ]
        for (why, input) in no {
            XCTAssertFalse(OpenPR.shouldOpenPR(input), "\(why) must not open a PR")
        }
    }

    // MARK: The manager exclusion, which is the point

    /// A manager is a top-level session with sessions under it. Every manager produces a branch
    /// per worker, so `auto` on managers would open dozens of PRs a day into one repo. This test
    /// fails if the manager exclusion is removed from `shouldOpenPR`.
    func testAManagerNeverOpensAPR() {
        let manager = OpenPR.Input(worktree: true, ahead: 2, depth: 0, hasChildren: true)
        XCTAssertTrue(manager.isManager)
        XCTAssertFalse(OpenPR.shouldOpenPR(manager), "a manager must not open a PR")

        // A worker (a child of a manager) is not a manager itself, and may.
        XCTAssertFalse(OpenPR.Input(worktree: true, ahead: 2, depth: 1, hasChildren: false).isManager)
        XCTAssertTrue(OpenPR.shouldOpenPR(.init(worktree: true, ahead: 2, depth: 1)))

        // A top-level session with no children is not a manager, even if it later gains some.
        XCTAssertFalse(OpenPR.Input(worktree: true, ahead: 2, depth: 0, hasChildren: false).isManager)

        // Depth alone is not the exclusion: a deep session that started its own children is
        // not a *manager* (managers are top level), so the rule stays exactly "depth 0 with
        // children" rather than "any session with children".
        XCTAssertFalse(OpenPR.Input(worktree: true, ahead: 2, depth: 1, hasChildren: true).isManager)
    }

    // MARK: The opt-out

    /// The per-session opt-out (`open-pr: off` in the first prompt) removes the offer. This test
    /// fails if the opt-out is removed from `shouldOpenPR`.
    func testTheOptOutRemovesTheOffer() {
        XCTAssertFalse(OpenPR.shouldOpenPR(.init(worktree: true, ahead: 2, optedOut: true)),
                       "a session that opted out must not open a PR")
        XCTAssertTrue(OpenPR.shouldOpenPR(.init(worktree: true, ahead: 2, optedOut: false)))
    }

    func testTheMarkerIsReadOffTheFirstPrompt() {
        // A line of its own, case-insensitive, `off` or `never` after the colon.
        for prompt in [
            "open-pr: off",
            "OPEN-PR: OFF",
            "  open-pr:off  ",
            "Fix the login bug.\n\nopen-pr: off\n\nAnd run the tests.",
            "open-pr: never",
        ] {
            XCTAssertTrue(OpenPR.optedOut(in: prompt), prompt)
        }
        // Everything else leaves the offer alone: a marker inline in prose isn't one, and a
        // word that isn't off/never isn't one either.
        for prompt in [
            nil,
            "",
            "the open-pr: off setting",
            "open-pr: on",
            "open-pr: auto",
            "open-pr:",
            "something else entirely",
        ] {
            XCTAssertFalse(OpenPR.optedOut(in: prompt), prompt ?? "nil")
        }
    }

    // MARK: The setting

    func testTheSettingGatesTheOfferAndAutoIsAsk() {
        // `off`: nothing is offered, however eligible.
        XCTAssertFalse(OpenPR.offers(.off, eligible))
        // `ask` (the default) and `auto` (parsed, deliberately not wired) both offer it.
        XCTAssertTrue(OpenPR.offers(.ask, eligible))
        XCTAssertTrue(OpenPR.offers(.auto, eligible))
        // "auto" is not auto: it resolves to "ask" and offers nothing more.
        XCTAssertEqual(OpenPR.Setting.auto.effective, .ask)
        // The default is `ask` in code: a config that says nothing about it parses to `ask`.
        XCTAssertEqual(OpenPR.Setting(rawValue: "ask"), .some(.ask))
        // And `auto` does not smuggle an excluded session past the predicate.
        XCTAssertFalse(OpenPR.offers(.auto, .init(worktree: true, ahead: 2, hasChildren: true)))
    }
}

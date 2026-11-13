import XCTest
@testable import Frog

/// The sidebar's PR status and the composer's pill say the same thing about a thread
/// (`docs/plans/2026-11-12-composer-tray.md`). They used to read two different sources: the
/// composer from the engine's bound PRs (every one, with its state), the sidebar from a single
/// PR number scraped out of git's ancestor scan. So three merged PRs read "3 PRs, all merged" in
/// the composer and "#312" in the row, and the other two were invisible.
@MainActor
final class SidebarPrTests: XCTestCase {
    private func pr(_ n: Int, _ state: ComposerModel.PrState) -> ComposerModel.Pr {
        .init(repo: "muni-works/frog", number: n, title: "PR \(n)", state: state, checks: .init(ok: 0, total: 0))
    }

    override func tearDown() {
        GitIndex.shared.unstage()
        Library.shared.unstage()
    }

    /// The crux: a row for a thread with no conversation open still knows its PRs, because the
    /// listing carries them. Nothing about the row needs a `Conversation`.
    func testARowWithNoOpenConversationStillShowsTheBoundPRs() {
        let closed = PrBinding(repo: "muni-works/frog", number: 312, title: "chip hover",
                               state: "merged", checks: [4, 4])
        let session = SessionInfo(id: "s1", modified: 0, created: 0, model: "m",
                                  firstInput: nil, title: "chip hover", end: .complete,
                                  forkedFrom: nil, cwd: "/tmp/frog-sidebar-pr",
                                  parent: nil, prs: [closed])
        Library.shared.stage(sessions: [session])
        XCTAssertNil(Library.shared.conversation("s1"), "no conversation open, as on a cold launch")

        let line = Library.shared.rowLine(session)
        XCTAssertEqual(line.prs?.label, "#312", "the row reads the listing's binding")
        XCTAssertEqual(line.prs?.worst, .merged)
    }

    /// One PR: the pill and the row both say "#312".
    func testOnePRReadsTheSameInBothPlaces() {
        let bound = [PrBinding(repo: "muni-works/frog", number: 312, title: "chip hover", state: "merged")]
        let composer = ComposerModel.summary(GitIndex.shared.prs(bound))
        let row = ComposerModel.summary(GitIndex.shared.prs(bound))
        XCTAssertEqual(composer?.label, "#312")
        XCTAssertEqual(row?.label, "#312")
        XCTAssertEqual(RowStatus.of(.done, prs: row), .pr(composer!))
    }

    /// Three PRs, two merged and one failing: both surfaces name the worst state and the count,
    /// and neither silently drops the two the old git scan couldn't see.
    func testThreePRsAgreeOnCountAndWorstState() {
        let bound = [
            PrBinding(repo: "muni-works/frog", number: 300, title: "a", state: "merged"),
            PrBinding(repo: "muni-works/frog", number: 301, title: "b", state: "failing"),
            PrBinding(repo: "muni-works/frog", number: 302, title: "c", state: "merged"),
        ]
        let composer = ComposerModel.summary(GitIndex.shared.prs(bound))
        XCTAssertEqual(composer?.count, 3)
        XCTAssertEqual(composer?.worst, .failing)
        XCTAssertEqual(composer?.label, "3 PRs, 1 failing")
        XCTAssertEqual(RowStatus.of(.done, prs: composer), .pr(composer!))
    }

    /// All merged: the wording the composer has, and the worst state merged.
    func testAllMergedReadsAllMergedInBothPlaces() {
        let bound = [
            PrBinding(repo: "muni-works/frog", number: 300, title: "a", state: "merged"),
            PrBinding(repo: "muni-works/frog", number: 301, title: "b", state: "merged"),
            PrBinding(repo: "muni-works/frog", number: 302, title: "c", state: "merged"),
        ]
        let composer = ComposerModel.summary(GitIndex.shared.prs(bound))
        XCTAssertEqual(composer?.label, "3 PRs, all merged")
        XCTAssertEqual(composer?.worst, .merged)
        XCTAssertEqual(RowStatus.of(.done, prs: composer), .pr(composer!))
    }

    /// The summary is one derivation: what the composer's pill renders is what the row renders.
    func testTheComposerAndTheRowUseOneSummary() {
        let state = ComposerModel.State(
            model: .init(id: "m", name: "m", place: .local, node: nil),
            where: .session(.init(repo: "muni-works/frog", branch: "b", worktree: false,
                                  worktreePath: nil, diff: .init(add: 0, del: 0, files: 0),
                                  dirty: false, ahead: 0,
                                  prs: [pr(300, .merged), pr(301, .merged), pr(302, .merged)])))
        let pill = ComposerModel.derive(state).prSummary
        let row = ComposerModel.summary(GitIndex.shared.prs(
            [.init(repo: "muni-works/frog", number: 300, state: "merged"),
             .init(repo: "muni-works/frog", number: 301, state: "merged"),
             .init(repo: "muni-works/frog", number: 302, state: "merged")]))
        XCTAssertEqual(pill, row, "the pill and the row are the same summary, not two like it")
    }

    /// A thread with nothing bound keeps the git-landed number it had: an old branch that went
    /// in still says so.
    func testWithNoBindingTheLandedNumberStillShows() {
        var badge = GitBadge(tree: "/tmp/frog-sidebar-pr")
        badge.branch = "frog/x"
        badge.base = "origin/main"
        badge.ahead = 0
        badge.landed = .pr(271)
        GitIndex.shared.stage(["s2": badge])
        let session = SessionInfo(id: "s2", modified: 0, created: 0, model: "m", firstInput: nil,
                                  title: "older work", end: .complete, forkedFrom: nil,
                                  cwd: "/tmp/frog-sidebar-pr")
        XCTAssertEqual(Library.shared.rowLine(session).prs?.label, "#271")
    }

    /// Seen or not, the row never invents a verdict for a PR nobody has looked at: a bound PR
    /// with no state in the log is "checks running", which is what the composer says too.
    func testAnUnknownStateReadsTheSameInBothPlaces() {
        let bound = [PrBinding(repo: "muni-works/frog", number: 9, title: "new")]
        XCTAssertEqual(GitIndex.shared.prs(bound).first?.state, .checks)
        XCTAssertEqual(ComposerModel.summary(GitIndex.shared.prs(bound))?.label, "#9")
    }
}

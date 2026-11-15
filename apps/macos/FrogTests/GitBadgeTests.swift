import XCTest
@testable import Frog

/// Sidebar git badges (docs/design/sidebar-git): what a row draws, how groups sum their
/// children, and what git's output reads as.
final class GitBadgeTests: XCTestCase {
    private func badge(_ tree: String, ahead: Int? = 0, dirty: Int? = 0, landed: GitBadge.Landed = .no,
                       trouble: GitBadge.Trouble? = nil, main: Bool = false, branch: String? = "frog/x") -> GitBadge {
        GitBadge(tree: tree, branch: branch, base: "origin/main", ahead: ahead, dirty: dirty, landed: landed,
                 trouble: trouble, mainCheckout: main)
    }

    func testRunningRowsHideTheDirtyDot() {
        let b = badge("/t", ahead: 3, dirty: 4)
        XCTAssertEqual(b.display(settled: false)?.dirty, false)
        XCTAssertEqual(b.display(settled: true)?.dirty, true)
        XCTAssertEqual(b.display(settled: true)?.ahead, 3)
    }

    func testDirtyWithNothingAheadShowsTheGlyphAlone() {
        let d = badge("/t", ahead: 0, dirty: 2).display(settled: true)
        XCTAssertEqual(d?.ahead, nil)
        XCTAssertEqual(d?.dirty, true)
        XCTAssertEqual(d?.showsBranch, true)
    }

    func testAheadWinsOverLanded() {
        // Merged once, then two more commits: the tip isn't in base, so it isn't landed.
        let d = badge("/t", ahead: 2, landed: .ancestor).display(settled: true)
        XCTAssertEqual(d?.ahead, 2)
        XCTAssertEqual(d?.landed, 0)
    }

    func testLandedLeafAndNothing() {
        XCTAssertEqual(badge("/t", landed: .patchEquivalent).display(settled: true)?.landed, 1)
        XCTAssertNil(badge("/t").display(settled: true))
    }

    func testMainCheckoutDirtIsNotTheRows() {
        let b = badge("/repo", ahead: 0, dirty: 40, main: true, branch: "main")
        XCTAssertNil(b.display(settled: true))
        XCTAssertTrue(GitSummary.of([(b, true)]).isEmpty)
    }

    func testTroubleOnlyOnceSettled() {
        let b = badge("/t", ahead: 5, trouble: .rebasing)
        XCTAssertNil(b.display(settled: false)?.trouble)
        XCTAssertEqual(b.display(settled: true)?.trouble, .rebasing)
        XCTAssertFalse(GitSummary.of([(b, false)]).trouble)
        XCTAssertTrue(GitSummary.of([(b, true)]).trouble)
    }

    func testSummarySumsAndDedupesTrees() {
        // v4 and v5 share one tree: its 10 commits count once.
        let s = GitSummary.of([
            (badge("/a", ahead: 10), true), (badge("/a", ahead: 10), true),
            (badge("/b", ahead: 7), false), (badge("/c", landed: .ancestor), true),
            (badge("/d", landed: .pr(97)), true), (badge("/e", ahead: 1, dirty: 3), false),
        ])
        XCTAssertEqual(s.ahead, 18)
        XCTAssertEqual(s.landed, 2)
        XCTAssertFalse(s.dirty, "only a running tree is dirty")
    }

    func testSharedTreeIsSettledOnlyWhenAllAre() {
        let s = GitSummary.of([(badge("/a", ahead: 1, dirty: 2), true), (badge("/a", ahead: 1, dirty: 2), false)])
        XCTAssertFalse(s.dirty)
    }

    // MARK: Rollup

    func testSubtreeAndFoldMembers() {
        let kids = ["m": ["w1", "w2", "w3"], "w2": ["g"]]
        let children: (String) -> [String] = { kids[$0] ?? [] }
        XCTAssertEqual(Set(GitRollup.subtree("m", children: children)), ["m", "w1", "w2", "w3", "g"])
        func row(_ id: String, _ depth: Int) -> SessionNesting.Entry {
            .row(SessionInfo(id: id, modified: 0, created: 0, model: "", firstInput: nil, title: id, end: nil,
                             forkedFrom: nil, cwd: nil), depth: depth, counts: .init(), collapsed: false)
        }
        // A fold holds `children(parent)` the rows didn't already draw. Since the sidebar went
        // to one level, the folds are the root ones ("N done by chief", "yours:") — nothing
        // folds inside a session — so here the chief's fold takes its undrawn children.
        let chiefKids = ["m": ["w1", "w2", "w3"]]
        let chiefChildren: (String) -> [String] = { $0 == AttentionTree.chiefFold ? ["m"] : chiefKids[$0] ?? [] }
        let closed: [SessionNesting.Entry] = [
            .done(parent: AttentionTree.chiefFold, depth: 0, count: 1, failed: 0, open: false),
        ]
        XCTAssertEqual(GitRollup.foldMembers(closed, children: chiefChildren)[AttentionTree.chiefFold], ["m"])
        // Open, its members are drawn after it — and still count, since they aren't "before".
        let open = closed + [row("m", 0)]
        XCTAssertEqual(GitRollup.foldMembers(open, children: chiefChildren)[AttentionTree.chiefFold], ["m"])
    }

    // MARK: Parsing

    func testAheadBehind() {
        let out = """
        1111 refs/heads/frog/accounts-ux-spec 17 133
        2222 refs/heads/main 0 0
        bad line
        """
        let refs = GitParse.aheadBehind(out)
        XCTAssertEqual(refs["frog/accounts-ux-spec"], .init(sha: "1111", ahead: 17, behind: 133))
        XCTAssertEqual(refs["main"]?.ahead, 0)
        XCTAssertEqual(refs.count, 2)
    }

    func testStatus() {
        let out = """
        # branch.oid abc
        # branch.head frog/x
        1 .M N... 100644 100644 100644 a b src/a.rs
        2 R. N... 100644 100644 100644 a b R100 new\told
        u UU N... 100644 100644 100644 100644 a b c conflicted.rs
        ? untracked.txt
        ! ignored.o
        """
        let s = GitParse.status(out)
        XCTAssertEqual(s.dirty, 4)
        XCTAssertEqual(s.conflicts, 1)
    }

    func testHeadAndReflog() {
        XCTAssertEqual(GitParse.head("ref: refs/heads/frog/sidebar-git\n").branch, "frog/sidebar-git")
        XCTAssertEqual(GitParse.head("9e02a1c0ffee\n").sha, "9e02a1c0ffee")
        XCTAssertNil(GitParse.head("9e02a1c0ffee\n").branch)
        let reflog = "0000000000000000000000000000000000000000 77b5f8c1 Cam <c@x> 1761480000 -0400\tbranch: Created from origin/main\n77b5f8c1 6badefc2 Cam <c@x> 1761480100 -0400\tcommit: notes\n"
        XCTAssertEqual(GitParse.created(reflog), "77b5f8c1")
    }

    func testMerges() {
        let rs = "\u{1e}", fs = "\u{1f}"
        let out = [
            ["b36d033", "1ef090c c55ee8b", "1761480000", "Merge remote-tracking branch 'origin/frog/subagent-visibility'", ""],
            ["92fabc4", "aaaa bbbb", "1761400000", "Merge pull request #104 from ecto/transcript-virtualization",
             "transcript: instant session switch + virtualization (5000-row <100ms)\n"],
            ["f1ede00", "cccc dddd", "1761300000", "Merge branch 'frog/drain-fleet'", ""],
            ["eeee", "ffff", "1761200000", "not a merge", ""],
        ].map { $0.joined(separator: fs) }.joined(separator: rs + "\n") + rs
        let m = GitParse.merges(out)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[0].branch, "frog/subagent-visibility")
        XCTAssertEqual(m[0].brought, ["c55ee8b"])
        XCTAssertNil(m[0].pr)
        XCTAssertEqual(m[1].pr, 104)
        XCTAssertEqual(m[1].branch, "transcript-virtualization")
        XCTAssertEqual(m[1].title, "transcript: instant session switch + virtualization (5000-row <100ms)")
        XCTAssertEqual(m[2].branch, "frog/drain-fleet")
    }

    func testShortstat() {
        XCTAssertEqual(GitParse.shortstat(" 21 files changed, 1751 insertions(+), 378 deletions(-)\n"),
                       .init(files: 21, added: 1751, removed: 378))
        XCTAssertEqual(GitParse.shortstat(" 1 file changed, 310 insertions(+)\n"), .init(files: 1, added: 310, removed: 0))
        XCTAssertEqual(GitParse.shortstat(""), .init())
    }

    func testSlugAndLinks() {
        XCTAssertEqual(GitParse.slug(remote: "git@github.com:ecto/frog.git\n"), "ecto/frog")
        XCTAssertEqual(GitParse.slug(remote: "https://github.com/muni-works/frog"), "muni-works/frog")
        XCTAssertNil(GitParse.slug(remote: "git@gitlab.com:ecto/frog.git"))
        XCTAssertEqual(GitLinks.pr("ecto/frog", 97)?.absoluteString, "https://github.com/ecto/frog/pull/97")
        XCTAssertEqual(GitLinks.commit("ecto/frog", "b36d033")?.absoluteString, "https://github.com/ecto/frog/commit/b36d033")
        XCTAssertEqual(GitLinks.compare("ecto/frog", base: "main", branch: "frog/x")?.absoluteString,
                       "https://github.com/ecto/frog/compare/main...frog/x")
    }
}

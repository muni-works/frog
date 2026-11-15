import XCTest
@testable import Frog

/// Forks and resumes of the same worktree branch fold into one sidebar row.
final class SessionFoldsTests: XCTestCase {
    private func session(_ id: String, modified: Int64, cwd: String? = nil, fork: String? = nil) -> SessionInfo {
        SessionInfo(
            id: id, modified: modified, created: modified, model: "m",
            firstInput: nil, title: id, end: nil,
            forkedFrom: fork.map { SessionInfo.ForkPoint(session: $0, seq: 0) }, cwd: cwd)
    }

    private let repo = "/Users/cam/Developer/frog"
    private func worktree(_ name: String) -> String { "\(repo)/.claude/worktrees/\(name)" }

    func testSessionsInTheSameWorktreeFoldOntoTheNewest() {
        let old = session("old", modified: 100, cwd: worktree("feat"))
        let newer = session("newer", modified: 300, cwd: worktree("feat"))
        let newest = session("newest", modified: 200, cwd: worktree("feat"))

        let folds = SessionFolds.group([old, newer, newest])

        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual(folds[0].session.id, "newer")
        XCTAssertEqual(folds[0].older.map(\.id), ["newest", "old"])
    }

    func testDifferentWorktreesStaySeparate() {
        let a = session("a", modified: 100, cwd: worktree("one"))
        let b = session("b", modified: 200, cwd: worktree("two"))
        let folds = SessionFolds.group([a, b])
        XCTAssertEqual(folds.map(\.session.id).sorted(), ["a", "b"])
        XCTAssertTrue(folds.allSatisfy { !$0.folded })
    }

    func testForksJoinTheirSourceEvenElsewhere() {
        let base = session("base", modified: 100, cwd: repo)
        let forked = session("forked", modified: 200, cwd: repo, fork: "base")
        let folds = SessionFolds.group([base, forked])
        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual(folds[0].session.id, "forked")
        XCTAssertEqual(folds[0].older.map(\.id), ["base"])
    }

    func testForkWithNoSourceListedStandsAlone() {
        let orphan = session("orphan", modified: 100, fork: "gone")
        let plain = session("plain", modified: 200, cwd: repo)
        let folds = SessionFolds.group([orphan, plain])
        XCTAssertEqual(folds.map(\.session.id).sorted(), ["orphan", "plain"])
    }

    func testPlainSessionsAreUntouched() {
        let a = session("a", modified: 100, cwd: "/tmp/one")
        let b = session("b", modified: 200, cwd: "/tmp/two")
        let folds = SessionFolds.group([a, b])
        XCTAssertEqual(folds.map(\.session.id), ["b", "a"])
        XCTAssertTrue(folds.allSatisfy { !$0.folded })
    }

    private func titled(_ id: String, _ title: String, modified: Int64, cwd: String) -> SessionInfo {
        SessionInfo(id: id, modified: modified, created: modified, model: "m",
                    firstInput: nil, title: title, end: nil, forkedFrom: nil, cwd: cwd)
    }

    func testARedoneTaskFoldsUnderItsParent() {
        // The manager restarted "chief queue gate fix" in another repo's worktree.
        let first = titled("first", "chief queue gate fix", modified: 100, cwd: worktree("chief-queue-gate-fix"))
        let redo = titled("redo", "Chief  queue gate fix", modified: 200, cwd: "/Users/cam/Developer/chief/.frog/worktrees/chief-queue-gate-fix")
        let other = titled("other", "frog tool bugs", modified: 150, cwd: worktree("bugs"))
        let parents = ["first": "mgr", "redo": "mgr", "other": "mgr"]
        let folds = SessionFolds.group([first, redo, other], parent: { parents[$0] })
        XCTAssertEqual(folds.map(\.session.id), ["redo", "other"])
        XCTAssertEqual(folds[0].older.map(\.id), ["first"])
    }

    func testSameTitleUnderDifferentParentsStaysApart() {
        let a = titled("a", "fix tests", modified: 100, cwd: "/tmp/a")
        let b = titled("b", "fix tests", modified: 200, cwd: "/tmp/b")
        let parents = ["a": "m1", "b": "m2"]
        XCTAssertEqual(SessionFolds.group([a, b], parent: { parents[$0] }).count, 2)
        XCTAssertEqual(SessionFolds.group([a, b]).count, 2, "no parents, no title folding")
    }

    func testUntitledSessionsNeverFoldByTitle() {
        let a = SessionInfo(id: "a", modified: 1, created: 1, model: "m", firstInput: "hi", title: nil, end: nil, forkedFrom: nil, cwd: "/tmp/a")
        let b = SessionInfo(id: "b", modified: 2, created: 2, model: "m", firstInput: "hi", title: nil, end: nil, forkedFrom: nil, cwd: "/tmp/b")
        XCTAssertEqual(SessionFolds.group([a, b], parent: { _ in "m" }).count, 2)
    }

    func testWorktreePathDetection() {
        XCTAssertEqual(SessionFolds.worktreePath(URL(fileURLWithPath: worktree("feat"))), worktree("feat"))
        XCTAssertNil(SessionFolds.worktreePath(URL(fileURLWithPath: repo)))
        XCTAssertNil(SessionFolds.worktreePath(nil))
    }
}

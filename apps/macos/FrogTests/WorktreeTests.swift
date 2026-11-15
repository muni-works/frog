import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The composer's worktree menu: what `git worktree list --porcelain` parses into, and
/// what a fresh repo with worktrees offers.
@MainActor
final class WorktreeTests: XCTestCase {
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-wt-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func run(_ args: String...) { Git.run(dir, args) }
        run("init", "-q", "--initial-branch=main")
        run("config", "user.email", "frog@example.com")
        run("config", "user.name", "frog")
        Git.run(dir, ["remote", "add", "origin", dir.path]) // no fetch: origin/HEAD won't resolve
        try "hi\n".write(to: dir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        run("add", ".")
        run("commit", "-q", "-m", "first")
        run("branch", "main") // "origin/main" never resolves without a fetch, so base falls back
        return dir
    }

    func testParsesWorktrees() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertTrue(Git.run(repo, ["worktree", "add", "-q", "-b", "frog/fix", repo.appending(path: ".frog/worktrees/fix").path, "main"]) != nil)
        // A tree of some other tooling's making, outside `.frog/worktrees`: not the menu's.
        XCTAssertTrue(Git.run(repo, ["worktree", "add", "-q", "-b", "other", "/tmp/frog-wt-other-\(UUID().uuidString.prefix(4))", "main"]) != nil)
        let (trees, _) = WorktreeIndex.read(repo)
        XCTAssertEqual(trees.map(\.name), [repo.lastPathComponent, "fix"], "main first, then frog's own trees; the outsider stays out")
        let fix = trees.last!
        XCTAssertEqual(fix.branch, "frog/fix")
        XCTAssertEqual(fix.isMain, false)
        XCTAssertNil(fix.owner, "no engine runs in a fresh tree")
    }

    func testMainCheckoutFallsBackClean() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (trees, base) = WorktreeIndex.read(repo)
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees.first?.name, repo.lastPathComponent)
        XCTAssertEqual(trees.first?.isMain, true)
        XCTAssertNil(base, "no remote to base a tree on in this fixture")
    }
}

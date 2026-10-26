import XCTest
@testable import Frog

/// `GitIndex` against a real repo in a temp dir: an origin, a main checkout and four worktrees
/// (ahead, merged, fresh, dirty). It checks what the badges read, not how they draw.
@MainActor
final class GitIndexTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gitindex-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ dir: URL, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
        return text
    }

    private func commit(_ dir: URL, _ file: String, _ message: String) throws {
        try "\(message)\n".write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
        try git(dir, "add", file)
        try git(dir, "commit", "-q", "-m", message)
    }

    private func session(_ id: String, _ dir: URL) -> SessionInfo {
        SessionInfo(id: "gi-\(id)-\(root.lastPathComponent)", modified: 1, created: 1, model: "m", firstInput: nil, title: "\(id) work",
                    end: .complete, forkedFrom: nil, cwd: dir.path)
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done(), "timed out waiting for \(what)")
    }

    func testBadgesFromARealRepo() throws {
        let origin = root.appending(path: "origin.git")
        let repo = root.appending(path: "repo")
        try git(root, "init", "-q", "--bare", "-b", "main", origin.path)
        try git(root, "init", "-q", "-b", "main", repo.path)
        try commit(repo, "a.txt", "first")
        try git(repo, "remote", "add", "origin", origin.path)
        try git(repo, "push", "-q", "-u", "origin", "main")
        try git(repo, "remote", "set-head", "origin", "main")
        func tree(_ name: String) throws -> URL {
            let dir = repo.appending(path: ".frog/worktrees/\(name)")
            try git(repo, "worktree", "add", "-q", "-b", "frog/\(name)", dir.path, "origin/main")
            return dir
        }
        let a = try tree("a"), b = try tree("b"), c = try tree("c"), d = try tree("d")
        try commit(a, "a1.txt", "a one")
        try commit(a, "a2.txt", "a two")
        try commit(b, "b1.txt", "b one")
        try git(repo, "merge", "-q", "--no-ff", "-m", "Merge branch 'frog/b'", "frog/b")
        try git(repo, "push", "-q", "origin", "main")
        try "edit\n".write(to: d.appending(path: "a.txt"), atomically: true, encoding: .utf8)

        let index = GitIndex.shared
        let sessions = [session("a", a), session("b", b), session("c", c), session("d", d), session("main", repo)]
        index.listingChanged(sessions)
        sessions.forEach(index.wantStatus)
        wait("badges") { sessions.prefix(4).allSatisfy { index.badge($0)?.dirty != nil && index.badge($0)?.base != nil } }

        let ba = try XCTUnwrap(index.badge(sessions[0]))
        XCTAssertEqual(ba.branch, "frog/a")
        XCTAssertEqual(ba.base, "origin/main")
        XCTAssertEqual(ba.ahead, 2)
        XCTAssertEqual(ba.behind, 2, "b's commit and its merge")
        XCTAssertFalse(ba.isLanded)
        XCTAssertEqual(ba.display(settled: true)?.ahead, 2)

        let bb = try XCTUnwrap(index.badge(sessions[1]))
        XCTAssertTrue(bb.isLanded, "merged into origin/main")
        XCTAssertEqual(bb.display(settled: true)?.landed, 1)

        // Fresh off origin/main, nothing of its own: no badge, not "landed".
        let bc = try XCTUnwrap(index.badge(sessions[2]))
        XCTAssertFalse(bc.isLanded)
        XCTAssertNil(bc.display(settled: true))

        let bd = try XCTUnwrap(index.badge(sessions[3]))
        XCTAssertEqual(bd.dirty, 1)
        XCTAssertEqual(bd.display(settled: true)?.dirty, true)
        XCTAssertEqual(bd.display(settled: false)?.dirty ?? false, false)

        // The main checkout on its base branch shows nothing.
        XCTAssertNil(index.badge(sessions[4]))

        // The group: a's 2 ahead, b landed, d dirty.
        let sum = GitSummary.of(sessions.compactMap { s in index.badge(s).map { ($0, true) } })
        XCTAssertEqual(sum.ahead, 2)
        XCTAssertEqual(sum.landed, 1)
        XCTAssertTrue(sum.dirty)

        // The card: b's merge (no GitHub remote: no link), a not landed, stats on first load.
        let card = index.card(sessions)
        XCTAssertEqual(card.landed.map(\.title), ["b work"])
        XCTAssertNil(card.landed.first?.url)
        XCTAssertEqual(card.pending.map(\.title), ["a work"])
        index.load(card, commitsFor: card.pending.first)
        wait("stats") {
            card.landed.allSatisfy { index.stats[$0.statKey ?? ""] != nil }
                && card.pending.first.flatMap { $0.commitsKey.flatMap { index.commits[$0] } } != nil
        }
        XCTAssertEqual(index.stats[card.landed[0].statKey ?? ""]?.added, 1)
        XCTAssertEqual(index.commits[card.pending[0].commitsKey ?? ""]?.map(\.subject), ["a two", "a one"])

        // A commit lands through the ref watcher: a goes to 3 ahead without anyone asking.
        try commit(a, "a3.txt", "a three")
        wait("ref watcher", timeout: 15) { index.badge(sessions[0])?.ahead == 3 }
    }
}

import XCTest
@testable import Frog

/// Starting an engine in a worktree another engine runs in never happens: the open, the
/// restore and the broker's restart each check the tree's owner first and show the reason
/// instead of an engine that dies at birth. One real repo, one worktree, one held lock —
/// as the engine writes it.
@MainActor
final class WorktreeHoldTests: XCTestCase {
    private var repo: URL!
    private var worktree: URL!
    private var lockFD: Int32 = -1
    /// Where the engine would write (a scratch HOME) and which binary it would run (none).
    private var overrides: [String: String] = [:]
    private var restoreBinary: URL?

    override func setUpWithError() throws {
        // Resolved: git reports /private/var/… for this path, and WorktreeIndex.read filters
        // by the resolved top's prefix.
        repo = FileManager.default.temporaryDirectory
            .appending(path: "frog-hold-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try SessionBroker.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try SessionBroker.git(["add", "."], in: repo)
        try SessionBroker.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        let (wt, _, _) = try SessionBroker.makeWorktree(from: repo, name: "hold")
        worktree = wt
        // The tests here never run an engine: Frog.binary is pointed at a missing path, so a
        // spawn fails loudly ("Couldn't start frog") rather than reaching the real sessions
        // (the bundled one ships in the test host's own bundle).
        restoreBinary = Frog.binary
        Frog.forcedBinaryForTesting = URL(fileURLWithPath: "/nonexistent/frog-for-hold-tests")
        overrides = Frog.overrides
        Frog.overrides = ["HOME": repo.appending(path: "home").path]
        let session = SessionInfo(id: "eng-0002", modified: 0, created: 0, model: "m", firstInput: nil,
                                  title: "Owner", end: nil, forkedFrom: nil, cwd: wt.path)
        Library.shared.stage(sessions: [session])
    }

    override func tearDown() async throws {
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        Frog.forcedBinaryForTesting = restoreBinary
        Frog.overrides = overrides
        Library.shared.unstage()
        try? FileManager.default.removeItem(at: repo)
    }

    /// The lock, held as an engine holds it: the file names its owner.
    private func hold(for owner: String) throws {
        guard case .worktree(_, let gitDir) = SessionBroker.checkout(of: worktree) else {
            return XCTFail("not a worktree")
        }
        let lock = gitDir.appending(path: "frog-engine.lock")
        try "\(owner) 4242\n".write(to: lock, atomically: true, encoding: .utf8)
        lockFD = open(lock.path, O_RDONLY)
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0, "the test holds the lock")
    }

    /// The owner is another session: opening the session here shows the hold (the
    /// transcript's red line) and starts no engine.
    func testOpeningAnOwnedSessionSpawnsNothingAndNamesTheHold() throws {
        try hold(for: "eng-0009")
        let workspace = Workspace(folder: worktree, resume: "eng-0002")
        let c = try XCTUnwrap(workspace.conversation)
        XCTAssertNil(c.link, "no engine was even attempted")
        let failure = try XCTUnwrap(c.failure)
        XCTAssertTrue(failure.contains("session eng-0009"), failure)
        XCTAssertTrue(failure.contains("already has an engine"), failure)
        XCTAssertTrue(failure.contains(".frog/worktrees/hold"), failure)
        XCTAssertTrue(failure.contains("One engine per worktree"), failure)
        XCTAssertTrue(failure.contains("resumable once eng-0009 stops"), failure)
        // And it isn't live: the composer shows the reason, nothing to send into.
        XCTAssertFalse(c.isLive)
    }

    /// The owner is the same session: `worktreeHold` says reuse (no hold), so the spawn
    /// proceeds — the session's own engine is never a refusal for it. (The broker's pane
    /// open reaches the same answer by adopting the live engine first; a preview
    /// conversation can't stand in for one here, so the reuse is pinned at `worktreeHold`,
    /// the decision both paths go through.)
    func testTheSameSessionResumingItsOwnTreeIsAReuseNotARefusal() throws {
        try hold(for: "eng-0002")
        XCTAssertNil(Workspace.worktreeHold(of: worktree, resumed: "eng-0002"),
                     "the owner resuming its own tree reuses it")
        // A different session into the same held tree is refused.
        XCTAssertNotNil(Workspace.worktreeHold(of: worktree, resumed: "eng-9999"))
    }

    /// A free worktree opens the session as before: the spawn is attempted (it stops at the
    /// missing binary here), and no hold refusal stands in its way.
    func testAFreeWorktreeSpawnsWithoutARefusal() throws {
        let workspace = Workspace(folder: worktree, resume: "eng-0002")
        let c = try XCTUnwrap(workspace.conversation)
        let failure = c.failure
        XCTAssertFalse(failure?.contains("already has an engine") ?? false,
                       "a free tree isn't a hold: \(failure ?? "")")
        XCTAssertTrue(failure?.hasPrefix("Couldn't start frog") ?? false,
                      "the spawn was attempted, not refused: \(failure ?? "(none)")")
    }

    /// A folder that doesn't exist must not hang the walk: `standardizedFileURL` keeps ".."
    /// segments for a missing path, so `deletingLastPathComponent` grew it forever and
    /// `checkout` never reached a root (every StartSession and every open goes through it).
    func testAFolderThatDoesNotExistIsPlainAndReturns() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "frog-missing-\(UUID().uuidString)/nested/deeper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(SessionBroker.checkout(of: missing), .plain)
        XCTAssertNil(Workspace.worktreeOwner(of: missing, resumed: nil))
        XCTAssertNil(Workspace.worktreeHold(of: missing, resumed: nil))
    }

    /// The beachball at launch, pinned so a regression fails fast instead of hanging the
    /// suite: a restored window can pass a RELATIVE folder URL, which `resolvingSymlinksInPath`
    /// alone leaves relative, so the walk went "." → ".." forever on the main thread. The
    /// timeout expectation is the guard — without the absolute-first fix this never returns.
    func testARelativeFolderURLIsPlainAndReturnsBeforeTheTimeout() {
        let relative = URL(fileURLWithPath: "relative-folder-\(UUID().uuidString.prefix(6))/nested")
        XCTAssertFalse(relative.path.hasPrefix("/"), "the case under test is a relative path")
        let returned = XCTestExpectation(description: "checkout of a relative URL returns")
        var result: SessionBroker.Checkout?
        DispatchQueue.global().async {
            result = SessionBroker.checkout(of: relative)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5)
        XCTAssertEqual(result, .plain, "a relative folder outside any repo is .plain")
    }

    /// ".." segments must land on the right absolute place, not just terminate: the walk
    /// above a dotted path must reach the repo that lives there.
    func testDotDotSegmentsResolveToTheRightAbsolutePlace() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "frog-dotdot-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base.appending(path: "repo/sub"), withIntermediateDirectories: true)
        try SessionBroker.git(["init", "-q", "-b", "main"], in: base.appending(path: "repo"))
        // `.frog/worktrees` is what makes the repo count as a main checkout for `checkout`.
        try FileManager.default.createDirectory(at: base.appending(path: "repo/.frog/worktrees"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dotted = base.appending(path: "repo/sub/../inside")
        guard case .main(let top) = SessionBroker.checkout(of: dotted) else {
            return XCTFail("the walk above the .. should reach the repo")
        }
        XCTAssertEqual(top.resolvingSymlinksInPath().path,
                       base.appending(path: "repo").resolvingSymlinksInPath().path)
    }

    /// The composer's worktree menu: the owned tree is disabled and names its engine; a free
    /// tree is enabled again.
    func testTheWorktreeMenuDisablesOwnedTrees() throws {
        try hold(for: "eng-0009")
        let (trees, _) = WorktreeIndex.read(repo)
        let mine = try XCTUnwrap(trees.first { $0.name == worktree.lastPathComponent }, "the owned tree is listed")
        XCTAssertEqual(mine.owner, "eng-0009")
        // The fresh tree the menu would offer after the owner stops is enabled again.
        close(lockFD); lockFD = -1
        let (freed, _) = WorktreeIndex.read(repo)
        let tree = try XCTUnwrap(freed.first { $0.name == worktree.lastPathComponent }, "still listed once free")
        XCTAssertNil(tree.owner)
    }

    /// Bug 3, the agent's side: a `StartSession` into a held worktree is refused with the
    /// owner named, and the asking session's transcript carries the same line (the user
    /// reads that pane, not the model's tool result).
    func testStartSessionIntoAHeldWorktreeIsRefusedWithTheOwnerNamed() async throws {
        try hold(for: "eng-0009")
        // The asking session: an engine-less conversation with one turn, so a note has a row
        // to land on.
        let parent = Conversation(preview: repo)
        try parent.ingest(JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"chief-0001","created":1,"event":"turn_started","turn":1,"input":"go"}"#.utf8)))
        let broker = SessionBroker.shared
        let req = SessionBroker.StartRequest(
            title: "worker", prompt: "do the thing", cwd: worktree.path,
            model: nil, mode: nil, worktree: false)
        do {
            _ = try await broker.starterForTesting(req, parent: parent)
            XCTFail("a held worktree must not start a session")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("session eng-0009"), message)
            XCTAssertTrue(message.contains("already has an engine"), message)
            XCTAssertTrue(message.contains("One engine per worktree"), message)
        }
        // The user sees it too, in the session they're watching.
        let notes = parent.turns.flatMap(\.items).filter { if case .notice = $0.kind { true } else { false } }
        let text = notes.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("session eng-0009"), "the asking session's transcript says why: \(text)")
        XCTAssertTrue(text.contains("already has an engine"), text)
    }

    /// Bug 3, the other half: a fresh worktree is always the way out, so the refusal's
    /// advice is one press away rather than a dead end.
    func testAFreshWorktreeIsFreeEvenWhileAnotherIsHeld() throws {
        try hold(for: "eng-0009")
        let (dir, branch, _) = try SessionBroker.makeWorktree(from: repo, name: "another")
        defer { try? SessionBroker.git(["worktree", "remove", "--force", dir.path], in: repo) }
        XCTAssertNotEqual(dir.path, worktree.path)
        XCTAssertEqual(branch, "frog/another")
        XCTAssertNil(Workspace.worktreeOwner(of: dir, resumed: "eng-0002"),
                     "the new tree has no engine in it")
    }
}

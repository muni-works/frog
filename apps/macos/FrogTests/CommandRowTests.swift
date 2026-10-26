import XCTest
@testable import Frog

/// The tool row's command UX: gist preview when cached, elided-command fallback, the
/// hash-keyed gist cache (one gist per unique command), and path elision against the
/// session root.
@MainActor
final class CommandRowTests: XCTestCase {
    private let root = "/Users/cam/Developer/frog/.frog/worktrees/tool-row-ux"

    // MARK: Elision

    func testElisionMakesWorktreePathsRelative() {
        // The shape from Cam's screenshot: the worktree path eats the line raw, elides to
        // its worktree tail whatever the session root is (here a sibling worktree).
        XCTAssertEqual(
            CommandElision.elide("cd /Users/cam/Developer/frog/.frog/worktrees/sleep-events && git --no-optional-locks log --oneline -5", from: root),
            "cd worktrees/sleep-events && git --no-optional-locks log --oneline -5")
        // A command outside the session root (and not a worktree) stays absolute.
        XCTAssertEqual(
            CommandElision.elide("cd /tmp/elsewhere && ls", from: root),
            "cd /tmp/elsewhere && ls")
        // No paths at all: untouched.
        XCTAssertEqual(
            CommandElision.elide("git log --oneline -5", from: root),
            "git log --oneline -5")
        // Under the session root: relative; the root itself is a dot.
        XCTAssertEqual(CommandElision.elide("cd \(root)", from: root), "cd .")
        XCTAssertEqual(CommandElision.elide("ls \(root)/apps", from: root), "ls apps")
        // A trailing slash on the root doesn't double-elide.
        XCTAssertEqual(CommandElision.elide("cd \(root)/x", from: root + "/"), "cd x")
    }

    func testElisionKeepsSeparatorsAndQuotes() {
        XCTAssertEqual(
            CommandElision.elide("cd \(root)/a; ls \(root)/b && cat \(root)/c, done", from: root),
            "cd a; ls b && cat c, done")
        // Each quote character keeps its own shape.
        XCTAssertEqual(
            CommandElision.elide("ls \"\(root)/quoted\" '\(root)/single'", from: root),
            "ls \"quoted\" 'single'")
    }

    // MARK: The gist cache

    func testIdenticalCommandsShareOneGist() {
        let gists = CommandGists.shared
        gists.reset()
        let command = "git --no-optional-locks log --oneline -5"
        gists.record(command: command, gist: "git log of the worktree")
        // A second event for the same command is a no-op: the first line stays.
        gists.record(command: command, gist: "a different line that must not win")
        XCTAssertEqual(gists.gist(for: command), "git log of the worktree")
        // Two rows with the same command read the same gist (hash-keyed).
        XCTAssertEqual(gists.gist(for: command), gists.gist(for: command))
        // An empty gist never lands (the engine never sends one, and the row falls back).
        gists.record(command: "cargo test", gist: "")
        XCTAssertNil(gists.gist(for: "cargo test"))
        gists.reset()
    }

    // MARK: The preview line's fallback

    func testPreviewFallsBackToTheElidedCommandWhilePendingOrUnavailable() {
        // No gist recorded: the row shows the elided command, never a blank line.
        let gists = CommandGists.shared
        gists.reset()
        let command = "cd /Users/cam/Developer/frog/.frog/worktrees/sleep-events && git --no-optional-locks log --oneline -5"
        XCTAssertNil(gists.gist(for: command))
        XCTAssertEqual(
            CommandElision.elide(command, from: root),
            "cd worktrees/sleep-events && git --no-optional-locks log --oneline -5")
        // With a gist, the same lookup answers (dart available, cached).
        gists.record(command: command, gist: "git log of the worktree")
        XCTAssertEqual(gists.gist(for: command), "git log of the worktree")
        gists.reset()
    }

    // MARK: The event decodes and lands in the cache

    private var seq: UInt64 = 0

    private func ingest(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"row","created":1790113417019,"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    func testCommandGistedEventDecodesAndRecords() throws {
        let gists = CommandGists.shared
        gists.reset()
        let c = Conversation(folder: URL(fileURLWithPath: root), link: nil, replay: false)
        ingest(c, #""command_gisted","item":"t1","command":"git log --oneline -5","gist":"git log of the sleep-events worktree""#)
        XCTAssertEqual(gists.gist(for: "git log --oneline -5"), "git log of the sleep-events worktree")
        // A duplicate command in a later turn reuses the one gist (hash cache).
        ingest(c, #""command_gisted","item":"t2","command":"git log --oneline -5","gist":"second""#)
        XCTAssertEqual(gists.gist(for: "git log --oneline -5"), "git log of the sleep-events worktree")
        gists.reset()
    }
}


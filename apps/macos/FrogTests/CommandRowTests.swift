import XCTest
@testable import Frog

/// The tool row's command UX: the gist preview when the engine's side-model sent one, the
/// elided-command fallback, and path elision against the session root.
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

    // MARK: The row's words

    /// The gist is per item, not per command: two rows running the same command each keep
    /// their own line, and a row with none falls back to the elided command.
    func testTheGistBelongsToTheRow() {
        var gisted = ItemState(id: "t1", kind: .tool(name: "Bash", arg: "git log --oneline -5"))
        gisted.gist = "git log of the sleep-events worktree"
        XCTAssertEqual(gisted.gist, "git log of the sleep-events worktree")
        let bare = ItemState(id: "t2", kind: .tool(name: "Bash", arg: "git log --oneline -5"))
        XCTAssertNil(bare.gist)
        // The fallback is the elided command, never a blank line.
        let command = "cd /Users/cam/Developer/frog/.frog/worktrees/sleep-events && git --no-optional-locks log --oneline -5"
        XCTAssertEqual(
            CommandElision.elide(command, from: root),
            "cd worktrees/sleep-events && git --no-optional-locks log --oneline -5")
    }

    // MARK: The event decodes and lands on its row

    private var seq: UInt64 = 0

    private func ingest(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"row","created":1790113417019,"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    func testItemGistedEventDecodesAndLandsOnTheRow() throws {
        let c = Conversation(folder: URL(fileURLWithPath: root), link: nil, replay: false)
        ingest(c, #""item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"git log --oneline -5"}"#)
        ingest(c, #""item_gisted","item":"t1","gist":"git log of the sleep-events worktree""#)
        let row = c.turns.last?.items.first { $0.id == "t1" }
        XCTAssertEqual(row?.gist, "git log of the sleep-events worktree")
        // A different row keeps its own (absent) line: nothing is shared by command.
        ingest(c, #""item_started","id":"t2","kind":{"type":"tool_call","name":"Bash","arg":"git log --oneline -5"}"#)
        let bare = c.turns.last?.items.first { $0.id == "t2" }
        XCTAssertNil(bare?.gist)
    }

    /// An empty gist never arrives, but if one did it clears rather than showing a blank.
    func testAnEmptyGistLeavesTheRowOnItsArgument() throws {
        let c = Conversation(folder: URL(fileURLWithPath: root), link: nil, replay: false)
        ingest(c, #""item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
        ingest(c, #""item_gisted","item":"t1","gist":"""#)
        let row = c.turns.last?.items.first { $0.id == "t1" }
        XCTAssertNil(row?.gist)
    }
}

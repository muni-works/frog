import XCTest
@testable import Frog

/// Archiving from a view: archiving the session on screen clears the view; archiving any other
/// session leaves the user where they are; unarchiving never navigates. The rule lives in
/// `ArchiveNav` and every view goes through it, so this tests the one place instead of each menu.
@MainActor
final class ArchiveNavTests: XCTestCase {
    /// `Library.shared` persists to the host app's defaults (toys.frog.dev, shared with every
    /// dev build): put back whatever a real archive held.
    private var saved: Any?
    private let key = "archivedSessions"

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: The decision (pure: no window, no engine)

    func testArchivingTheSessionOnScreenForwards() {
        XCTAssertTrue(ArchiveNav.shouldForward(afterArchiving: "s1", current: "s1"))
    }

    func testArchivingAnotherSessionStaysPut() {
        XCTAssertFalse(ArchiveNav.shouldForward(afterArchiving: "s2", current: "s1"),
                       "a row you aren't reading archives away without moving you")
    }

    func testNothingOnScreenHasNowhereToForwardFrom() {
        XCTAssertFalse(ArchiveNav.shouldForward(afterArchiving: "s1", current: nil),
                       "a new, empty view archives an old row without jumping")
    }

    /// The automatic archive is safe by construction: it only folds sessions no window shows, so
    /// it never meets the one case that forwards. (Library.archiveQuietChats filters on
    /// `window(for:) == nil`; it doesn't call this helper at all.)
    func testAutomaticArchiveCannotNavigate() {
        XCTAssertFalse(ArchiveNav.shouldForward(afterArchiving: "quiet", current: "something else"))
    }

    // MARK: Performing it

    /// A workspace showing session `id`, with no engine behind it: a conversation with a session
    /// id and no link is enough — navigation is all this needs to observe.
    private func workspace(showing id: String) -> Workspace {
        let dir = FileManager.default.temporaryDirectory.appending(path: "archive-nav-\(UUID().uuidString)")
        let workspace = Workspace(folder: dir, fresh: true)
        workspace.testShow(Conversation(folder: dir, link: nil, replay: false, session: id, failure: "test"))
        XCTAssertEqual(workspace.showing, id, "the workspace really is showing it")
        return workspace
    }

    /// Archiving the conversation on screen archives it *and* clears the view.
    func testArchivingTheOpenSessionForwardsTheView() {
        let id = "test-\(UUID().uuidString)"
        let workspace = workspace(showing: id)
        defer {
            workspace.stop()
            Library.shared.setArchived(id, false)
        }

        var forwarded = 0
        ArchiveNav.archive(id, from: workspace, forward: { _ in forwarded += 1 })

        XCTAssertTrue(Library.shared.archived.contains(id), "archived")
        XCTAssertEqual(forwarded, 1, "and the view followed, exactly once")
    }

    /// Archiving any other row archives it and leaves the view alone.
    func testArchivingAnotherSessionLeavesTheViewAlone() {
        let shown = "shown-\(UUID().uuidString)"
        let other = "other-\(UUID().uuidString)"
        let workspace = workspace(showing: shown)
        defer {
            workspace.stop()
            Library.shared.setArchived(shown, false)
            Library.shared.setArchived(other, false)
        }

        var forwarded = 0
        ArchiveNav.archive(other, from: workspace, forward: { _ in forwarded += 1 })

        XCTAssertTrue(Library.shared.archived.contains(other), "archived")
        XCTAssertEqual(forwarded, 0, "but the user stayed where they were")
    }

    /// Unarchiving is not this helper's path at all (the archive's row calls `setArchived(id,
    /// false)` directly), so nothing can navigate from it. Pinned here so a later refactor that
    /// routes unarchive through a helper has to keep the rule.
    func testUnarchiveIsOneWayAndNeverForwards() {
        let id = "test-\(UUID().uuidString)"
        let workspace = workspace(showing: id)
        defer { workspace.stop() }
        Library.shared.setArchived(id, true)
        Library.shared.setArchived(id, false)
        XCTAssertFalse(Library.shared.archived.contains(id))
        XCTAssertEqual(workspace.showing, id, "showing the restored session is not a navigation")
    }

    /// An engine that records being stopped: the conversation on screen in a worktree holds
    /// that worktree's lock, so archiving has to stop it before a new session can start there.
    private final class StoppableLink: ConversationLink {
        var onEvent: (Envelope?) -> Void = { _ in }
        func send(_ op: Op) {}
        var stopped = false
        func stop() { stopped = true }
        var endDescription: String { "" }
        var isAlive: Bool { true }
    }

    /// The bug this guards: archiving the session on screen in a worktree showed the refusal
    /// ("one engine per worktree…") instead of a new conversation, because the archived
    /// session's engine still held the lock. The engine must be stopped as part of the archive.
    ///
    /// Removing `leaving?.stop(reason: "archived")` fails this — the conversation that was on
    /// screen is still alive afterwards.
    func testArchivingTheOpenSessionStopsItsEngine() async throws {
        let id = "test-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appending(path: "archive-nav-\(UUID().uuidString)")
        let workspace = Workspace(folder: dir, fresh: true)
        let link = StoppableLink()
        let leaving = Conversation(folder: dir, link: link, replay: false, session: id)
        workspace.testShow(leaving)
        defer {
            workspace.stop()
            Library.shared.setArchived(id, false)
        }
        XCTAssertTrue(link.isAlive, "the engine is running before the archive")

        ArchiveNav.archive(id, from: workspace)

        XCTAssertTrue(link.stopped, "archiving what's on screen stops its engine, freeing the worktree")
    }

    // MARK: The default the views actually get

    /// The test above injects the forward, so it would still pass with the real navigation
    /// deleted — it proves the decision, not that a view moves. This one calls the helper the
    /// way the menus do, with the default `newSession()`, and watches the screen change.
    /// Removing `forward(workspace)` (or the default's `newSession()`) fails it.
    func testTheDefaultForwardReallyReplacesTheConversationOnScreen() async throws {
        let id = "test-\(UUID().uuidString)"
        let workspace = workspace(showing: id)
        defer {
            workspace.stop()
            Library.shared.setArchived(id, false)
        }
        let before = workspace.conversation
        XCTAssertEqual(workspace.showing, id)

        ArchiveNav.archive(id, from: workspace)  // exactly what the row menu and title menu call
        // The real navigation stops the engine first and starts the new session once its
        // worktree is free, so it lands a moment later.
        let deadline = ContinuousClock.now + .seconds(5)
        while workspace.showing == id, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(Library.shared.archived.contains(id), "archived")
        XCTAssertFalse(workspace.conversation === before, "the archived conversation left the screen")
        XCTAssertNotEqual(workspace.showing, id, "and the view is no longer showing the archived session")
    }

    /// The same call for another session changes nothing on screen.
    func testTheDefaultForwardLeavesAnotherSessionsViewExactlyAlone() {
        let shown = "shown-\(UUID().uuidString)"
        let other = "other-\(UUID().uuidString)"
        let workspace = workspace(showing: shown)
        defer {
            workspace.stop()
            Library.shared.setArchived(shown, false)
            Library.shared.setArchived(other, false)
        }
        let before = workspace.conversation

        ArchiveNav.archive(other, from: workspace)

        XCTAssertTrue(Library.shared.archived.contains(other), "archived")
        XCTAssertTrue(workspace.conversation === before, "the same conversation, untouched")
        XCTAssertEqual(workspace.showing, shown, "still showing what it was showing")
        XCTAssertEqual(workspace.opening, nil, "and nothing opened in its place")
    }

    // MARK: The call sites

    /// The rule is only worth anything if the views call it. A menu that archives with
    /// `setArchived` directly (or with the broker's `archive`, which the agent tool shares)
    /// would leave the session on screen again, and every test above would still pass.
    func testEveryViewArchiveGoesThroughArchiveNav() throws {
        let views = [
            "Frog/Views/Sidebar.swift",           // the row's ⋯ menu
            "Frog/Views/WorkspaceView.swift",    // the title's ⌄ menu
            "Frog/Views/ComposerView+Tray.swift", // the git line's Archive (a merged PR)
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // FrogTests
            .deletingLastPathComponent()                                        // apps/macos
        for path in views {
            let src = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            XCTAssertTrue(src.contains("ArchiveNav.archive("), "\(path) archives a view's session through ArchiveNav")
            XCTAssertFalse(src.contains("SessionBroker.shared.archive("), "\(path) doesn't take the agent tool's path")
        }
    }

    /// The other half of the rule, and the half nothing else pins: the paths that must never
    /// navigate have to stay off the helper. If one of them is ever routed through `ArchiveNav`
    /// (a well-meant "share the code"), an agent archiving a peer or a phone command would yank
    /// a person's view, and every test above would still pass.
    func testPathsThatMustNotNavigateStayOffTheHelper() throws {
        let quiet = [
            "Frog/Model/SessionBroker.swift", // the ArchiveSession agent tool
            "Frog/Model/RemoteBridge.swift",  // the phone's manage command
            "Frog/Model/Library.swift",       // archiveQuietChats, and delete's own caller
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // FrogTests
            .deletingLastPathComponent()                                        // apps/macos
        for path in quiet {
            let src = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            XCTAssertFalse(src.contains("ArchiveNav"), "\(path) archives without moving anyone's view")
        }
    }

    /// The automatic fold is the one that would be silent: it runs on a refresh, with no user
    /// action to blame. The guard is the window test in its filter — a shown session is never
    /// eligible — so pin that it is still there.
    func testQuietChatsStillSkipsSessionsOnScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(contentsOf: root.appending(path: "Frog/Model/Library.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "private func archiveQuietChats")?.lowerBound)
        let body = String(src[start...].prefix(1200))
        XCTAssertTrue(body.contains("window(for: s.id) == nil"),
                      "the quiet fold only sees sessions no window shows")
    }
}

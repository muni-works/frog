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
        ArchiveNav.archive(id, from: workspace) { _ in forwarded += 1 }

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
        ArchiveNav.archive(other, from: workspace) { _ in forwarded += 1 }

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
}

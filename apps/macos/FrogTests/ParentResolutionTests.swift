import XCTest
@testable import Frog

/// Filing a session under another one: the recorded parent must always be a session the
/// sidebar can show. Cam archives managers routinely; a child filed under the archived one
/// pointed at an id with no row, and the tree dropped it to the root (dangling parents,
/// 2026-11-13). Both recording paths — `StartSession`'s `Library.setParent` and
/// `MoveSession`'s `Library.move` — resolve to a live parent instead.
@MainActor
final class ParentResolutionTests: XCTestCase {
    /// `Library.shared` persists parentage to the host app's defaults (toys.frog.dev, shared
    /// with every dev build): put back whatever real parentage held.
    private var saved: [String: Any] = [:]
    private static let keys = ["sessionParents", "archivedSessions"]

    override func setUp() {
        saved = Self.keys.reduce(into: [:]) { d, k in d[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        Library.shared.unstage()
        for k in Self.keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private static func session(_ id: String) -> SessionInfo {
        SessionInfo(id: id, modified: 1_000_000_000_000, created: 1_000_000_000_000, model: "m",
                    firstInput: nil, title: id, end: nil, forkedFrom: nil, cwd: "/tmp")
    }

    /// chief (live) ← manager (archived) ← worker (live): the shape archiving a manager
    /// leaves behind — the worker's recorded parent has no row any more.
    private func stageArchivedManager() {
        Library.shared.stage(
            sessions: [Self.session("chief-live"), Self.session("mgr-archived"), Self.session("worker")],
            parents: ["mgr-archived": "chief-live"],
            archived: ["mgr-archived"])
    }

    /// The invariant, asserted once: whatever is stored for `child` is a session the sidebar
    /// actually has a row for. A dangling reference reads as "the child fell to the root".
    private func assertParentIsLive(_ child: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let parent = Library.shared.parents[child] else {
            return XCTFail("\(child) is unparented: a top-level row, which is a valid answer only when no live ancestor survives", file: file, line: line)
        }
        XCTAssertNotNil(Library.shared.sessions.first { $0.id == parent },
                        "\(child)'s parent \(parent) isn't in the library: the sidebar has no row to nest under",
                        file: file, line: line)
        XCTAssertFalse(Library.shared.archived.contains(parent),
                       "\(child)'s parent \(parent) is archived: the sidebar hides it, so the child dangles",
                       file: file, line: line)
    }

    // MARK: StartSession's path

    /// A child started by a session that has since been archived files under the nearest live
    /// ancestor, not under the ghost.
    func testSetParentUnderAnArchivedManagerFilesUnderItsLiveParent() {
        stageArchivedManager()

        Library.shared.setParent(of: "worker", to: "mgr-archived")

        XCTAssertEqual(Library.shared.parents["worker"], "chief-live", "reparented to the live grandparent")
        assertParentIsLive("worker")
    }

    /// Nothing live survives the walk (every ancestor archived): the child is a top-level row
    /// rather than filed under a session with no row.
    func testSetParentWithNoLiveAncestorLeavesTheChildTopLevel() {
        Library.shared.stage(
            sessions: [Self.session("mgr-archived"), Self.session("worker")],
            parents: ["mgr-archived": "gone-0000"],  // and the grandparent isn't in the library at all
            archived: ["mgr-archived"])

        Library.shared.setParent(of: "worker", to: "mgr-archived")

        XCTAssertNil(Library.shared.parents["worker"], "unparented, not filed under an archived session")
    }

    /// An ordinary start: the caller is live, so nothing is rewritten.
    func testSetParentUnderALiveParentIsUnchanged() {
        Library.shared.stage(sessions: [Self.session("mgr-live"), Self.session("worker")])

        Library.shared.setParent(of: "worker", to: "mgr-live")

        XCTAssertEqual(Library.shared.parents["worker"], "mgr-live")
        assertParentIsLive("worker")
    }

    /// The user-visible outcome: the sidebar nests the child under the row that does exist.
    func testTheSidebarNestsTheChildUnderItsLiveGrandparent() {
        stageArchivedManager()

        Library.shared.setParent(of: "worker", to: "mgr-archived")

        let built = SessionList.attention(Library.shared, sort: .activity, scope: .all, current: nil)
        XCTAssertEqual(built.parentOf["worker"], "chief-live",
                       "the tree reads the resolved parent, so the row sits under the chief")
        XCTAssertFalse(built.layout.topLevels.contains { $0.id == "worker" },
                       "not back at the root: a top-level row is what the dangling reference caused")
    }

    // MARK: MoveSession's path

    /// Moving under an archived manager (a stale id from a listing the model still remembers)
    /// lands under the live ancestor.
    func testMoveUnderAnArchivedManagerFilesUnderItsLiveParent() {
        stageArchivedManager()

        let moved = Library.shared.move("worker", to: "mgr-archived")

        XCTAssertEqual(moved, .success("chief-live"), "the recorded parent comes back")
        XCTAssertEqual(Library.shared.parents["worker"], "chief-live")
        assertParentIsLive("worker")
    }

    /// An archived parent with nothing live above it: the move unparents rather than recording
    /// a reference with no row.
    func testMoveUnderAnArchivedManagerWithNoLiveAncestorUnparents() {
        Library.shared.stage(sessions: [Self.session("mgr-archived"), Self.session("worker")],
                             parents: ["worker": "mgr-archived"],
                             archived: ["mgr-archived"])

        let moved = Library.shared.move("worker", to: "mgr-archived")

        XCTAssertEqual(moved, .success(nil))
        XCTAssertNil(Library.shared.parents["worker"], "a top-level row again")
    }

    /// A live parent moves exactly where it was asked to, and still refuses a cycle.
    func testMoveUnderALiveParentIsUnchanged() {
        Library.shared.stage(sessions: [Self.session("chief-live"), Self.session("mgr-live"), Self.session("worker")],
                             parents: ["mgr-live": "chief-live"])

        XCTAssertEqual(Library.shared.move("worker", to: "mgr-live"), .success("mgr-live"))
        XCTAssertEqual(Library.shared.parents["worker"], "mgr-live")
        // The cycle guard still holds with resolution in front of it.
        XCTAssertEqual(Library.shared.move("chief-live", to: "worker"), .failure(.nestsWithinItself))
        XCTAssertNil(Library.shared.parents["chief-live"], "the refusal recorded nothing")
    }

    // MARK: The resolution itself

    /// `Library.liveParent` without the app's state: a live id is kept as asked, an archived or
    /// absent one walks up, and nothing that survives means unparented. The walk can't loop and
    /// can't make a session its own parent.
    func testLiveParentWalksPastArchivedAndAbsentIds() {
        let parents = ["archived-b": "gone-c", "gone-c": "live-d", "loop-a": "loop-b", "loop-b": "loop-a",
                       "outer": "child"]
        let sessions = ["archived-b", "live-d", "loop-a", "loop-b", "child"].map(Self.session)
        let resolve = { (wanted: String?) in
            Library.liveParent(wanted, of: "child", sessions: sessions, archived: ["archived-b"], parents: parents)
        }

        XCTAssertEqual(resolve("live-d"), "live-d", "a live parent is kept as asked")
        XCTAssertEqual(resolve("archived-b"), "live-d", "archived → up, past a vanished id, to the live one")
        XCTAssertEqual(resolve("gone-c"), "live-d", "absent from the library → up")
        XCTAssertNil(resolve("nowhere"), "nothing known: unparented")
        XCTAssertNil(resolve(nil), "no parent asked for: unparented")
        XCTAssertEqual(resolve("loop-a"), "loop-a", "a recorded cycle still terminates")
        XCTAssertNil(resolve("child"), "itself is never a candidate, even when the walk comes back to it")
        XCTAssertNil(Library.liveParent("outer", of: "child", sessions: sessions, archived: [],
                                        parents: parents), "a child is never its own ancestor")
    }
}

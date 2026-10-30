import XCTest
@testable import Frog

/// The chief of staff: one pinned session as a tile above everything else in the sidebar.
@MainActor
final class ChiefTests: XCTestCase {
    /// `Library.shared` persists to the host app's defaults (toys.frog.dev, shared with every
    /// dev build), so put back whatever a real chief and real pins were.
    private static let keys = ["chiefSession", "pinnedSessions", "archivedSessions"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        continueAfterFailure = false
        saved = Self.keys.reduce(into: [:]) { d, k in d[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        for k in Self.keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// The chief can't be unpinned out from under its tile; resigning first frees the pin.
    func testTheChiefKeepsItsPin() {
        let lib = Library.shared
        let id = "chief-tests-\(UUID().uuidString)"
        lib.makeChief(id)
        defer { lib.removeChief() }
        lib.togglePin(id)
        XCTAssertTrue(lib.pinned.contains(id), "Unpin is a no-op on the chief")
        lib.removeChief()
        lib.togglePin(id)
        XCTAssertFalse(lib.pinned.contains(id), "no longer chief, so it unpins like any pin")
    }

    /// `chiefSession` follows the id, and dropping the session drops the chief.
    func testChiefSessionResolvesAndClears() {
        let lib = Library.shared
        let id = "chief-tests-\(UUID().uuidString)"
        lib.makeChief(id)
        defer { lib.removeChief() }

        XCTAssertNil(lib.chiefSession, "no session with that id, so no tile")
        XCTAssertEqual(lib.chief, id, "but the chief itself is remembered across launches")
        XCTAssertTrue(lib.pinned.contains(id), "the chief keeps its pin, so the rail and phone still show it")

        lib.removeChief()
        XCTAssertNil(lib.chief)
        XCTAssertTrue(lib.pinned.contains(id), "the pin stays: it's a pin like any other now")
    }

    /// Making another session the chief moves the post, and only one is chief at a time.
    func testOnlyOneChief() {
        let lib = Library.shared
        let a = "chief-tests-a-\(UUID().uuidString)"
        let b = "chief-tests-b-\(UUID().uuidString)"
        lib.makeChief(a)
        defer { lib.removeChief() }
        lib.makeChief(b)
        XCTAssertEqual(lib.chief, b)
        XCTAssertNotEqual(lib.chief, a)
    }

    /// Archiving the chief resigns it, not archives a ghost tile.
    func testArchivingResigns() {
        let lib = Library.shared
        let id = "chief-tests-\(UUID().uuidString)"
        lib.makeChief(id)
        lib.setArchived(id, true)
        XCTAssertNil(lib.chief, "archived, so no longer the chief")
        XCTAssertNil(lib.chiefSession)
        lib.setArchived(id, false)
        XCTAssertFalse(lib.pinned.contains(id), "unarchiving doesn't re-pin; make it chief again if wanted")
    }
}

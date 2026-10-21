import XCTest
@testable import Frog

final class SessionDirectoryRescanTests: XCTestCase {
    func testDetectsNewChangedAndRemovedSessionLogs() {
        let first = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 101)

        let changed = SessionDirectoryRescan.changedSessions(
            previous: ["same": first, "updated": first, "removed": first],
            current: ["same": first, "updated": later, "added": first])

        XCTAssertEqual(changed, ["updated", "added", "removed"])
    }

    func testNoChangesProducesEmptySet() {
        let timestamp = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(SessionDirectoryRescan.changedSessions(
            previous: ["one": timestamp], current: ["one": timestamp]).isEmpty)
    }
}

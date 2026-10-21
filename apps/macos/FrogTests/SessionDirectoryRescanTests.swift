import XCTest
@testable import Frog

final class SessionDirectoryRescanTests: XCTestCase {
    func testDetectsNewChangedAndRemovedFlatSessionFiles() {
        let first = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 101)

        let changed = SessionDirectoryRescan.changedSessions(
            previous: ["20261021-182005-8519": first, "updated": first, "removed": first],
            current: ["20261021-182005-8519": first, "updated": later, "20261021-182006-1234": first])

        XCTAssertEqual(changed, ["updated", "20261021-182006-1234", "removed"])
    }

    func testNoChangesProducesEmptySet() {
        let timestamp = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(SessionDirectoryRescan.changedSessions(
            previous: ["one": timestamp], current: ["one": timestamp]).isEmpty)
    }
}

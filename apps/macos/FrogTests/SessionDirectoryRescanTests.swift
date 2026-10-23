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

    /// The watcher's state belongs to its queue: starting it (from main, as `Library` does) and
    /// letting its rescans run must never touch `files` or `snapshot` from two threads at once.
    /// Its scans assert they're on the queue, so a scan from anywhere else traps here; under
    /// Thread Sanitizer the old init-time scan on main reported the race with the queue's.
    func testWatcherScansOnlyOnItsQueue() {
        _ = SessionDirectoryWatcher.shared
        // Two rescans (one a second) on the queue after the first.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    }
}

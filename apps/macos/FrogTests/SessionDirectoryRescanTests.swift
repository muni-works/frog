import XCTest
@testable import Frog

final class SessionDirectoryRescanTests: XCTestCase {
    func testDetectsNewChangedAndRemovedFlatSessionFiles() {
        let first = (mtime: UInt64(100_000_000_000), size: UInt64(10))
        let later = (mtime: UInt64(101_000_000_000), size: UInt64(10))
        let grown = (mtime: UInt64(101_000_000_000), size: UInt64(11))

        let changed = SessionDirectoryRescan.changedSessions(
            previous: ["20261021-182005-8519": first, "updated": first, "removed": first],
            current: ["20261021-182005-8519": first, "updated": later, "appended": grown, "20261021-182006-1234": first])

        XCTAssertEqual(changed, ["updated", "appended", "20261021-182006-1234", "removed"])
    }

    func testNoChangesProducesEmptySet() {
        let stamp = (mtime: UInt64(100_000_000_000), size: UInt64(10))
        XCTAssertTrue(SessionDirectoryRescan.changedSessions(
            previous: ["one": stamp], current: ["one": stamp]).isEmpty)
    }

    /// A size-only change counts even when the mtime is unchanged (a writer that backdates):
    /// appends are detected, not missed.
    func testSizeChangeAloneCounts() {
        let before = (mtime: UInt64(100_000_000_000), size: UInt64(10))
        let after = (mtime: UInt64(100_000_000_000), size: UInt64(11))
        XCTAssertEqual(SessionDirectoryRescan.changedSessions(
            previous: ["one": before], current: ["one": after]), ["one"])
    }

    /// The watcher's state belongs to its queue: starting it (from main, as `Library` does) and
    /// letting its rescans run must never touch `files` or `snapshot` from two threads at once.
    /// Its scans assert they're on the queue, so a scan from anywhere else traps here; under
    /// Thread Sanitizer the old init-time scan on main reported the race with the queue's.
    func testWatcherScansOnlyOnItsQueue() {
        _ = SessionDirectoryWatcher.shared
        // Rescans, now one in ten seconds on the queue after the first.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    }

    /// The bulk read names every flat log with its stamp: same set and values as stat, in one
    /// syscall, with none of the per-URL work the old scan did.
    func testListingMatchesStat() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-rescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "20261103-120000-aaaa.jsonl")
        try Data("line\n".utf8).write(to: a)
        try Data("note".utf8).write(to: dir.appending(path: "20261103-120000-bbbb.json"))
        try Data("live".utf8).write(to: dir.appending(path: "20261103-120000-aaaa.live"))

        let listing = SessionDirectoryRescan.listing(dir.path)
        XCTAssertEqual(listing.keys.sorted(), ["20261103-120000-aaaa"], "only .jsonl files, .live and .json skipped")

        let stat = try a.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let (mtime, size) = try XCTUnwrap(listing["20261103-120000-aaaa"])
        XCTAssertEqual(mtime, UInt64(stat.contentModificationDate!.timeIntervalSince1970 * 1_000_000_000), accuracy: 2_000_000_000)
        XCTAssertEqual(size, UInt64(stat.fileSize ?? 0))
    }
}

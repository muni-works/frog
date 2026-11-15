import XCTest
@testable import Frog

/// One frog per build: a lock per bundle id and the decision that reads it. A Debug build
/// (toys.frog.dev) and the installed app (toys.frog) never block each other; a second copy of
/// the same build hands over. Every real-file test locks a scratch file of its own — the app's
/// own lock is never touched.
@MainActor
final class InstanceLockTests: XCTestCase {
    private var lock: URL!
    private var forced: URL?

    override func setUp() {
        lock = FileManager.default.temporaryDirectory
            .appending(path: "frog-inst-\(UUID().uuidString.prefix(6))/instance.lock")
            .resolvingSymlinksInPath()
        forced = LockHolder.pathForTesting
        LockHolder.pathForTesting = lock
    }

    override func tearDown() {
        LockHolder.pathForTesting = forced
        try? FileManager.default.removeItem(at: lock.deletingLastPathComponent())
    }

    /// A live pid for a holder line (this process is alive; a pid_t(Int32) truncation is fine
    /// for the test's purposes, but the real pid fits).
    private var livePid: pid_t { ProcessInfo.processInfo.processIdentifier }

    // MARK: the decision (pure)

    func testTheSameBundleIdHandsOff() {
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: "toys.frog",
                                               holderBundleId: "toys.frog", isTesting: false),
                       .handOff)
    }

    func testADifferentBundleIdRunsAlongside() {
        // The bug this fixes: a Debug build holding the shared lock made the installed app
        // exit silently. A different build is never a reason to leave.
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: "toys.frog.dev",
                                               holderBundleId: "toys.frog", isTesting: false),
                       .runAlongside)
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: "toys.frog",
                                               holderBundleId: "toys.frog.dev", isTesting: false),
                       .runAlongside)
    }

    func testEachBuildLocksItsOwnFile() throws {
        LockHolder.pathForTesting = nil
        let installed = try XCTUnwrap(LockHolder.path(bundleIdentifier: "toys.frog"))
        let debug = try XCTUnwrap(LockHolder.path(bundleIdentifier: "toys.frog.dev"))
        XCTAssertTrue(installed.path.hasSuffix("Application Support/Frog/instance.lock"), installed.path)
        XCTAssertTrue(debug.path.hasSuffix("Application Support/Frog/instance.toys.frog.dev.lock"), debug.path)
        XCTAssertEqual(LockHolder.path(bundleIdentifier: nil), installed)
        // Nothing in a bundle id can climb out of the folder.
        let odd = try XCTUnwrap(LockHolder.path(bundleIdentifier: "../../x/y"))
        XCTAssertEqual(odd.deletingLastPathComponent(), installed.deletingLastPathComponent())
    }

    /// Two builds hold their own locks at once (scratch files standing in for the two paths).
    func testTwoBuildsHoldLocksAtOnce() {
        let dir = lock.deletingLastPathComponent()
        LockHolder.pathForTesting = dir.appending(path: "instance.lock")
        let installed = LockHolder()
        XCTAssertEqual(installed.acquire(bundleIdentifier: "toys.frog"), .took)
        LockHolder.pathForTesting = dir.appending(path: "instance.toys.frog.dev.lock")
        let debug = LockHolder()
        XCTAssertEqual(debug.acquire(bundleIdentifier: "toys.frog.dev"), .took)
    }

    func testLaunchURLsKeepsURLsAndPathsAndSkipsDefaults() {
        let urls = SingleInstance.launchURLs([
            "/Applications/Frog.app/Contents/MacOS/Frog", "-psn_0_1234",
            "-FrogFolder", "/tmp/proj", "frog://session/abc", "/Users/me/code",
            "-NSDocumentRevisionsDebugMode", "YES",
        ])
        XCTAssertEqual(urls, [URL(string: "frog://session/abc")!, URL(fileURLWithPath: "/Users/me/code")])
    }

    func testTheConflictAlertNamesTheHolder() {
        let text = SingleInstance.conflictText(pid: 4242)
        XCTAssertEqual(text.title, "Frog is already running")
        XCTAssertTrue(text.body.contains("4242"))
        XCTAssertTrue(text.body.contains("Activity Monitor"))
    }

    func testAMissingBundleIdHandsOffNotQuiet() {
        // An older frog that wrote no bundle id: still one frog — hand over, don't stack.
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: "toys.frog",
                                               holderBundleId: nil, isTesting: false),
                       .handOff)
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: nil,
                                               holderBundleId: "toys.frog", isTesting: false),
                       .handOff)
    }

    func testADeadHolderIsReclaimed() {
        // A crash leaves the pid in the file; flock is already gone. The lock is ours.
        XCTAssertEqual(InstanceDecision.decide(holderPid: 999_999_999, myBundleId: "toys.frog",
                                               holderBundleId: "toys.frog", isTesting: false),
                       .takeLock)
        XCTAssertEqual(InstanceDecision.decide(holderPid: -1, myBundleId: "toys.frog",
                                               holderBundleId: "toys.frog", isTesting: false),
                       .takeLock)
    }

    func testTestingTakesTheLock() {
        // The test host never hands off or exits: xcodebuild test runs beside Cam's app.
        XCTAssertEqual(InstanceDecision.decide(holderPid: livePid, myBundleId: "toys.frog.testhost",
                                               holderBundleId: "toys.frog", isTesting: true),
                       .takeLock)
    }

    // MARK: the lock (real flock, on a scratch file)

    /// A second holder — a fresh LockHolder, as a second process would be — fails while the
    /// first holds it, and reads back who holds it.
    func testASecondAcquireFailsWhileAHolderLives() throws {
        let first = LockHolder()
        guard case .took = first.acquire(bundleIdentifier: "toys.frog") else {
            return XCTFail("the first acquire must take the scratch lock")
        }
        let second = LockHolder()
        guard case .held(let holder) = second.acquire(bundleIdentifier: "toys.frog.dev") else {
            return XCTFail("the second acquire must see the lock held")
        }
        XCTAssertEqual(holder.pid, livePid)
        XCTAssertEqual(holder.bundleIdentifier, "toys.frog")
        // The file names the holder: pid first, then the bundle id.
        let text = try String(contentsOf: lock, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").map(String.init), ["\(livePid)", "toys.frog"])
    }

    /// The kernel drops flock when the holder exits: after the holder's fd closes, the next
    /// acquire takes the lock even though the file still names the dead pid.
    func testAStaleLockFileIsReclaimedAfterTheHolderDies() throws {
        // Hold it the way a dead process would have left it: a taken file whose holder is
        // gone. The pid in the file must be one that's dead now — not this process, not
        // anything else alive (a just-exited child's pid can be reused; a huge pid can't).
        let dead = 999_999_999 as pid_t
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(dead)\ntoys.frog\n".write(to: lock, atomically: true, encoding: .utf8)
        // Sanity: that pid really is dead (kill says ESRCH, not alive, not EPERM).
        kill(dead, 0)
        XCTAssertEqual(errno, ESRCH, "the chosen pid must not be alive")
        let next = LockHolder()
        guard case .took = next.acquire(bundleIdentifier: "toys.frog") else {
            return XCTFail("a dead holder's lock is reclaimed")
        }
        // And it's ours now: the file names this process.
        let text = try String(contentsOf: lock, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("\(livePid)\n"), text)
    }

    /// The same file, two acquires at once, in-process: the second sees the first's lock —
    /// the shape `open -n` hits. (Covered by testASecondAskOnTheSameHolderReportsTaken.)

    /// The headless watcher and the handoff both ask; the second ask must not report the
    /// first's own lock as somebody else's (which would have exited the one real frog).
    func testASecondAskOnTheSameHolderReportsTaken() throws {
        let holder = LockHolder()
        guard case .took = holder.acquire(bundleIdentifier: "toys.frog") else {
            return XCTFail("first acquire takes it")
        }
        XCTAssertEqual(holder.acquire(bundleIdentifier: "toys.frog"), .took)
    }

    // MARK: the test-host exemption

    /// SingleInstance.otherIsRunning and handOff are no-ops in a test host: no lock taken,
    /// no exit — the suite runs beside Cam's app.
    func testTheTestHostTakesNoLockAndExitsNot() throws {
        let host = SingleInstance.isTesting
        XCTAssertTrue(host, "these tests run in a test host")
        XCTAssertFalse(SingleInstance.otherIsRunning)
        SingleInstance.handOff() // must return, not exit
        // And no lock file was created by that path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path),
                       "a test host takes no lock")
    }
}

import XCTest
@testable import Frog

/// The bridge's session rows: a phone renders the org from them, so `parent` (the started-by
/// link in `Library.parents`) has to round-trip, and `welcome` has to name the protocol version.
@MainActor
final class RemoteBridgeTests: XCTestCase {
    override func tearDown() {
        Library.shared.unstage()
    }

    /// `sessionList` puts each session's recorded parent in its row, and leaves roots alone.
    func testSessionRowsCarryTheParent() {
        let sessions = [
            SessionInfo(id: "bridge-mgr", modified: 2, created: 2, model: "m",
                        firstInput: nil, title: "bridge manager", end: nil, forkedFrom: nil, cwd: "/tmp"),
            SessionInfo(id: "bridge-worker", modified: 1, created: 1, model: "m",
                        firstInput: nil, title: "bridge worker", end: nil, forkedFrom: nil, cwd: "/tmp"),
        ]
        Library.shared.stage(sessions: sessions, parents: ["bridge-worker": "bridge-mgr"])

        let rows = RemoteBridge.shared.sessionList().reduce(into: [:]) { d, r in
            d[r["id"] as? String ?? ""] = r["parent"]
        }
        XCTAssertEqual(rows["bridge-worker"] as? String, "bridge-mgr", "the child names its parent")
        XCTAssertNil(rows["bridge-mgr"], "the root has no parent field")
    }
}

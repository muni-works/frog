import XCTest
@testable import Frog

/// The started-by tree: finished children fold under "+N done" so live work stands out.
final class SessionNestingTests: XCTestCase {
    private func session(_ id: String, modified: Int64) -> SessionInfo {
        SessionInfo(id: id, modified: modified, created: modified, model: "m",
                    firstInput: nil, title: id, end: nil, forkedFrom: nil, cwd: "/tmp")
    }

    private typealias State = SessionNesting.State

    /// A manager with workers in every state, newest-first by `modified`.
    private func rows(_ states: [String: State], parents: [String: String],
                      openDone: Set<String> = [], keep: Set<String> = [],
                      order: [String]) -> [SessionNesting.Entry] {
        let items = order.enumerated().map { i, id in session(id, modified: Int64(1000 - i)) }
        return SessionNesting.rows(
            items, parent: { parents[$0] }, state: { states[$0.id] ?? .done },
            before: { $0.modified > $1.modified }, openDone: openDone, keep: keep)
    }

    private func ids(_ entries: [SessionNesting.Entry]) -> [String] {
        entries.map { e in
            switch e {
            case .row(let s, let depth, _): String(repeating: ">", count: depth) + s.id
            case .done(_, let depth, let count, let failed, _):
                String(repeating: ">", count: depth) + "+\(count) done" + (failed > 0 ? " \(failed)x" : "")
            }
        }
    }

    func testFinishedChildrenCollapseUnderADoneRow() {
        let parents = ["a": "mgr", "b": "mgr", "c": "mgr", "d": "mgr"]
        let states: [String: State] = ["mgr": .done, "a": .done, "b": .running, "c": .failed, "d": .done]
        let out = rows(states, parents: parents, order: ["mgr", "a", "b", "c", "d"])
        XCTAssertEqual(ids(out), ["mgr", ">b", ">+3 done 1x"])
    }

    func testOpeningTheDoneRowListsThemBeneathIt() {
        let parents = ["a": "mgr", "b": "mgr"]
        let states: [String: State] = ["a": .done, "b": .running]
        let out = rows(states, parents: parents, openDone: ["mgr"], order: ["mgr", "a", "b"])
        XCTAssertEqual(ids(out), ["mgr", ">b", ">+1 done", ">a"])
    }

    func testAQuietManagerWithLiveWorkersStaysUp() {
        // chief → manager (idle) → worker (running): the manager isn't "done".
        let parents = ["mgr": "chief", "w": "mgr", "old": "chief"]
        let states: [String: State] = ["chief": .done, "mgr": .done, "w": .running, "old": .done]
        let out = rows(states, parents: parents, order: ["chief", "mgr", "w", "old"])
        XCTAssertEqual(ids(out), ["chief", ">mgr", ">>w", ">+1 done"])
    }

    func testTheSessionOnScreenIsNeverTuckedAway() {
        let parents = ["a": "mgr", "b": "mgr"]
        let out = rows(["a": .done, "b": .done], parents: parents, keep: ["a"], order: ["mgr", "a", "b"])
        XCTAssertEqual(ids(out), ["mgr", ">a", ">+1 done"])
    }

    func testRootsNeverCollapse() {
        let out = rows(["x": .done, "y": .failed], parents: [:], order: ["x", "y"])
        XCTAssertEqual(ids(out), ["x", "y"])
    }

    func testAParentCycleStillListsEveryoneOnce() {
        let out = rows(["a": .running, "b": .running], parents: ["a": "b", "b": "a"], order: ["a", "b"])
        XCTAssertEqual(ids(out), ["a", ">b"])
    }

    func testChildrenSortWaitingThenRunningThenTheRest() {
        // Newest first by the list's order: idle, running, waiting, unread, running2, failed.
        let parents = ["i": "m", "r": "m", "w": "m", "u": "m", "r2": "m", "f": "m"]
        let states: [String: State] = ["i": .done, "r": .running, "w": .waiting, "u": .unread, "r2": .running, "f": .failed]
        let out = rows(states, parents: parents, openDone: ["m"], order: ["m", "i", "r", "w", "u", "r2", "f"])
        XCTAssertEqual(ids(out), ["m", ">w", ">r", ">r2", ">u", ">+2 done 1x", ">f", ">i"])
    }

    func testAManagerSortsByItsWorkersUrgency() {
        // An idle manager whose worker waits on you sorts as waiting, ahead of a running one.
        let parents = ["busy": "chief", "mgr": "chief", "w": "mgr"]
        let states: [String: State] = ["busy": .running, "mgr": .done, "w": .waiting]
        let out = rows(states, parents: parents, order: ["chief", "busy", "mgr", "w"])
        XCTAssertEqual(ids(out), ["chief", ">mgr", ">>w", ">busy"])
    }

    func testRootsKeepTheListOrder() {
        let out = rows(["a": .done, "b": .waiting], parents: [:], order: ["a", "b"])
        XCTAssertEqual(ids(out), ["a", "b"])
    }

    func testStateFollowsTheGlyph() {
        XCTAssertEqual(State(.waiting), .waiting)
        XCTAssertEqual(State(.running), .running)
        XCTAssertEqual(State(.failed), .failed)
        XCTAssertTrue(State(.idle).settled)
        XCTAssertTrue(State(.failed).settled)
        XCTAssertFalse(State(.unread).settled)
    }
}

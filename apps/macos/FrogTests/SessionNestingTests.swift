import XCTest
@testable import Frog

/// The started-by tree, one level deep: expanding a session lists the children it started,
/// finished ones included. There is no second "+N done" fold inside a session.
final class SessionNestingTests: XCTestCase {
    private func session(_ id: String, modified: Int64) -> SessionInfo {
        SessionInfo(id: id, modified: modified, created: modified, model: "m",
                    firstInput: nil, title: id, end: nil, forkedFrom: nil, cwd: "/tmp")
    }

    private typealias State = SessionNesting.State

    /// A manager with workers in every state, newest-first by `modified`.
    private func rows(_ states: [String: State], parents: [String: String],
                      opened: Set<String> = [], keep: Set<String> = [],
                      collapsed: Set<String> = [], order: [String]) -> [SessionNesting.Entry] {
        let items = order.enumerated().map { i, id in session(id, modified: Int64(1000 - i)) }
        return SessionNesting.rows(
            items, parent: { parents[$0] }, state: { states[$0.id] ?? .done },
            before: { $0.modified > $1.modified }, opened: opened, keep: keep, collapsed: collapsed)
    }

    private func ids(_ entries: [SessionNesting.Entry]) -> [String] {
        entries.map { e in
            switch e {
            case .row(let s, let depth, _, let collapsed):
                String(repeating: ">", count: depth) + s.id + (collapsed ? " [-]" : "")
            case .done(_, let depth, let count, let failed, _):
                String(repeating: ">", count: depth) + "+\(count) done" + (failed > 0 ? " \(failed)x" : "")
            }
        }
    }

    /// Expanding a session shows every child it started: live and finished alike, on one
    /// level, with nothing folded in between (Cam: "only one level of accordions, not an extra
    /// for done/failed").
    func testFinishedChildrenAreRowsNotAFold() {
        let parents = ["a": "mgr", "b": "mgr", "c": "mgr", "d": "mgr"]
        let states: [String: State] = ["mgr": .done, "a": .done, "b": .running, "c": .failed, "d": .done]
        let out = rows(states, parents: parents, order: ["mgr", "a", "b", "c", "d"])
        XCTAssertEqual(ids(out), ["mgr", ">b", ">c", ">a", ">d"],
                       "most urgent first, then the finished ones by list order — no done row")
    }

    /// The old shape, kept as the test's reason for existing: no entry is a `.done` row for a
    /// parent, at any depth.
    func testNoParentGrowsADoneRow() {
        let parents = ["a": "mgr", "b": "mgr", "c": "a"]
        let states: [String: State] = ["mgr": .done, "a": .done, "b": .running, "c": .done]
        let out = rows(states, parents: parents, order: ["mgr", "a", "b", "c"])
        let done = out.filter { if case .done = $0 { return true } else { return false } }
        XCTAssertTrue(done.isEmpty, "one level: nothing folds inside a session")
        XCTAssertEqual(ids(out), ["mgr", ">b", ">a", ">>c"])
    }

    func testAQuietManagerWithLiveWorkersStaysUp() {
        // chief → manager (idle) → worker (running): the manager isn't "done".
        let parents = ["mgr": "chief", "w": "mgr", "old": "chief"]
        let states: [String: State] = ["chief": .done, "mgr": .done, "w": .running, "old": .done]
        let out = rows(states, parents: parents, order: ["chief", "mgr", "w", "old"])
        XCTAssertEqual(ids(out), ["chief", ">mgr", ">>w", ">old"])
    }

    func testTheSessionOnScreenIsNeverTuckedAway() {
        let parents = ["a": "mgr", "b": "mgr"]
        let out = rows(["a": .done, "b": .done], parents: parents, keep: ["a"], order: ["mgr", "a", "b"])
        XCTAssertEqual(ids(out), ["mgr", ">a", ">b"])
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
        let out = rows(states, parents: parents, order: ["m", "i", "r", "w", "u", "r2", "f"])
        XCTAssertEqual(ids(out), ["m", ">w", ">r", ">r2", ">u", ">f", ">i"],
                       "waiting, running, then the rest by list order; no done fold")
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

    func testACollapsedParentShowsOnlyItsCounts() {
        let parents = ["r1": "m", "r2": "m", "r3": "m", "r4": "m", "w": "m", "d": "m", "sub": "r1"]
        let states: [String: State] = ["m": .done, "r1": .running, "r2": .running, "r3": .running,
                                       "r4": .running, "w": .waiting, "d": .done, "sub": .running]
        let out = rows(states, parents: parents, collapsed: ["m"],
                       order: ["m", "r1", "r2", "r3", "r4", "w", "d", "sub"])
        XCTAssertEqual(ids(out), ["m [-]"], "no child rows, no done row")
        guard case .row(_, _, let counts, true)? = out.first else { return XCTFail("collapsed row") }
        XCTAssertEqual(counts, SessionNesting.Counts(waiting: 1, running: 4, done: 1))
        XCTAssertEqual(counts.summary, "4 running · 1 waiting · 1 done")
    }

    func testExpandedParentsCountTheirDirectChildren() {
        let parents = ["a": "m", "b": "m", "c": "a"]
        let out = rows(["a": .done, "b": .failed, "c": .waiting], parents: parents, order: ["m", "a", "b", "c"])
        guard case .row(_, _, let counts, false)? = out.first else { return XCTFail("expanded row") }
        // `a` counts as waiting: its own worker waits on you.
        XCTAssertEqual(counts, SessionNesting.Counts(waiting: 1, failed: 1))
        XCTAssertEqual(counts.total, 2)
    }

    /// A quiet manager (settled, nothing live under it) is one line until you open it — the one
    /// fold left, and it's the row's own disclosure, not a second row inside it.
    func testAQuietParentFoldsToOneLineUnlessOpened() {
        let parents = ["a": "m", "b": "m"]
        let states: [String: State] = ["m": .done, "a": .done, "b": .done]
        let items = [session("m", modified: 3), session("a", modified: 2), session("b", modified: 1)]
        let tree = { (opened: Set<String>) in
            SessionNesting.rows(items, parent: { parents[$0] }, state: { states[$0.id] ?? .done },
                                before: { $0.modified > $1.modified }, opened: opened, foldQuiet: true)
        }
        XCTAssertEqual(ids(tree([])), ["m [-]"], "nothing live under it: one line")
        XCTAssertEqual(ids(tree(["m"])), ["m", ">a", ">b"], "opened: its children, directly")
    }

    /// Archiving the session you're reading (#316) clears the view, so `keep` goes empty. The
    /// tree must still list every row: nothing vanishes because the kept id did.
    func testArchivingTheCurrentSessionLeavesTheTreeIntact() {
        let parents = ["a": "m", "b": "m"]
        let states: [String: State] = ["m": .done, "a": .done, "b": .done]
        let items = [session("m", modified: 3), session("a", modified: 2), session("b", modified: 1)]
        let withCurrent = SessionNesting.rows(
            items, parent: { parents[$0] }, state: { states[$0.id] ?? .done },
            before: { $0.modified > $1.modified }, keep: ["b"], foldQuiet: true)
        XCTAssertEqual(ids(withCurrent), ["m", ">a", ">b"], "the row on screen holds its parent open")

        // The view cleared: same tree, `keep` empty. Every session is still reachable — the
        // quiet parent folds to one line rather than the rows disappearing.
        let archived = SessionNesting.rows(
            items, parent: { parents[$0] }, state: { states[$0.id] ?? .done },
            before: { $0.modified > $1.modified }, keep: [], foldQuiet: true)
        XCTAssertEqual(ids(archived), ["m [-]"], "still one row, now folded")
        XCTAssertEqual(SessionNesting.blocks(archived).count, 1, "no block lost")
    }

    func testCollapsingAChildlessRowDoesNothing() {
        let out = rows(["x": .running], parents: [:], collapsed: ["x"], order: ["x"])
        XCTAssertEqual(ids(out), ["x"])
        XCTAssertNil(SessionNesting.Counts().summary)
    }

    func testBlocksKeepEachTreeWhole() {
        let parents = ["w": "mgr", "d": "mgr"]
        let out = rows(["mgr": .done, "w": .running, "d": .done, "solo": .done], parents: parents,
                       order: ["mgr", "w", "d", "solo"])
        let blocks = SessionNesting.blocks(out)
        XCTAssertEqual(blocks.map(\.root.id), ["mgr", "solo"])
        XCTAssertEqual(ids(blocks[0].entries), ["mgr", ">w", ">d"])
        XCTAssertEqual(ids(blocks[1].entries), ["solo"])
    }

    func testStateFollowsTheGlyph() {
        XCTAssertEqual(State(.waiting), .waiting)
        XCTAssertEqual(State(.running), .running)
        XCTAssertEqual(State(.failed), .failed)
        XCTAssertTrue(State(.idle).settled)
        XCTAssertTrue(State(.failed).settled)
        XCTAssertFalse(State(.unread).settled)
    }

    /// The phone's flat lists: a child follows its parent, one deeper; one whose parent
    /// isn't listed stays a root; a cycle loses nothing.
    func testIndentedKeepsOrderAndNestsChildren() {
        let parents = ["b": "a", "c": "b", "d": "gone", "e": "a", "x": "y", "y": "x"]
        let out = SessionNesting.indented(["a", "d", "b", "c", "e", "x", "y"]) { parents[$0] }
        XCTAssertEqual(out.map(\.id), ["a", "b", "c", "e", "d", "x", "y"])
        XCTAssertEqual(out.map(\.depth), [0, 1, 2, 1, 0, 0, 1])
    }

    /// The guide line's elbow goes on the last child at each depth.
    func testLastChildrenEndTheGuide() {
        func info(_ id: String) -> SessionInfo {
            SessionInfo(id: id, modified: 0, created: 0, model: "m", firstInput: nil, title: id, forkedFrom: nil, cwd: nil)
        }
        let e: [SessionNesting.Entry] = [
            .row(info("a"), depth: 0, counts: .init(), collapsed: false),
            .row(info("b"), depth: 1, counts: .init(), collapsed: false),
            .row(info("c"), depth: 2, counts: .init(), collapsed: false),
            .row(info("d"), depth: 1, counts: .init(), collapsed: false),
            .row(info("e"), depth: 0, counts: .init(), collapsed: false),
        ]
        XCTAssertEqual(SessionNesting.lastChildren(e), ["c", "d"], "the last child at each depth closes the guide")
    }
}

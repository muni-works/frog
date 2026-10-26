import XCTest
@testable import Frog

/// The attention tree: the chief's children as the top level, quiet managers folded to one
/// line, the chief's finished leaves in "N done by chief", yours below, and the scope.
final class AttentionTreeTests: XCTestCase {
    private typealias State = SessionNesting.State

    private func session(_ id: String, modified: Int64) -> SessionInfo {
        SessionInfo(id: id, modified: modified, created: modified, model: "m",
                    firstInput: nil, title: id, end: nil, forkedFrom: nil, cwd: "/tmp")
    }

    private func layout(_ states: [String: State], parents: [String: String], chief: String? = "chief",
                        scope: AttentionTree.Scope = .live, recent: Set<String> = [],
                        openDone: Set<String> = [], keep: Set<String> = [], order: [String]) -> AttentionTree.Layout {
        let items = order.enumerated().map { i, id in session(id, modified: Int64(1000 - i)) }
        return AttentionTree.layout(
            items, parent: { parents[$0] }, chief: chief, state: { states[$0.id] ?? .done },
            before: { $0.modified > $1.modified }, scope: scope, recent: { recent.contains($0.id) },
            openDone: openDone, keep: keep)
    }

    private func ids(_ entries: [SessionNesting.Entry]) -> [String] {
        entries.map { e in
            switch e {
            case .row(let s, let depth, _, let collapsed):
                String(repeating: ">", count: depth) + s.id + (collapsed ? " [-]" : "")
            case .done(let parent, let depth, let count, let failed, _):
                String(repeating: ">", count: depth) + "\(parent)+\(count)" + (failed > 0 ? " \(failed)x" : "")
            }
        }
    }

    /// chief › fm (busy) › w1 running, w2 done, w3 failed; chief › tang (quiet) › t1 done;
    /// chief › leaf (done), chief › live leaf; mine (Cam's own, running), old (Cam's, done).
    private let parents = ["fm": "chief", "w1": "fm", "w2": "fm", "w3": "fm",
                           "tang": "chief", "t1": "tang", "leaf": "chief", "lleaf": "chief"]
    private let states: [String: State] = ["chief": .running, "fm": .running, "w1": .running, "w2": .done,
                                            "w3": .failed, "tang": .done, "t1": .done, "leaf": .done,
                                            "lleaf": .waiting, "mine": .running, "old": .done]
    private let order = ["chief", "fm", "w1", "w2", "w3", "tang", "t1", "leaf", "lleaf", "mine", "old"]

    func testLiveScopeFoldsSettledWorkAndQuietManagers() {
        let out = layout(states, parents: parents, order: order)
        XCTAssertEqual(ids(out.org), ["fm", ">w1", ">fm+2 1x", "tang [-]", "lleaf", "chief:+1"])
        XCTAssertEqual(ids(out.yours), ["mine", "yours:+1"])
        XCTAssertEqual(out.topLevels.map(\.id), ["fm", "tang", "lleaf", "mine"])
    }

    func testNeedsYouIsALensOldestFirst() {
        var s = states
        s["w2"] = .waiting
        let out = layout(s, parents: parents, order: order)
        // Oldest first: lleaf (modified 992) before w2 (997); both keep their tree place.
        XCTAssertEqual(out.needsYou.map(\.id), ["lleaf", "w2"])
        XCTAssertTrue(ids(out.org).contains(">w2"))
        XCTAssertTrue(ids(out.org).contains("lleaf"))
    }

    func testAQuietManagerOpensThroughItsDoneRow() {
        let out = layout(states, parents: parents, openDone: ["tang"], order: order)
        XCTAssertEqual(Array(ids(out.org).drop(while: { $0 != "tang" }).prefix(3)), ["tang", ">tang+1", ">t1"])
    }

    func testTheSessionOnScreenIsNeverFolded() {
        let out = layout(states, parents: parents, keep: ["t1"], order: order)
        XCTAssertTrue(ids(out.org).contains("tang"))
        XCTAssertTrue(ids(out.org).contains(">t1"))
        let kept = layout(states, parents: parents, keep: ["leaf", "old"], order: order)
        XCTAssertTrue(ids(kept.org).contains("leaf"))
        XCTAssertEqual(ids(kept.yours), ["mine", "old"])
    }

    func testTodayShowsTodaysSettledWorkAndFoldsTheRestAsEarlier() {
        let out = layout(states, parents: parents, scope: .today, recent: ["w2", "leaf"], order: order)
        XCTAssertEqual(ids(out.org), ["fm", ">w1", ">w2", ">fm+1 1x", "tang [-]", "leaf", "lleaf"])
    }

    func testAllShowsEverything() {
        let out = layout(states, parents: parents, scope: .all, order: order)
        XCTAssertEqual(ids(out.org), ["fm", ">w1", ">w3", ">w2", "tang", ">t1", "leaf", "lleaf"])
        XCTAssertEqual(ids(out.yours), ["mine", "old"])
    }

    func testYoursKeepsFailuresInLiveScope() {
        var s = states
        s["old"] = .failed
        XCTAssertEqual(ids(layout(s, parents: parents, order: order).yours), ["mine", "old"])
    }

    func testWithoutAChiefRootsWithChildrenAreManagers() {
        let out = layout(states, parents: parents, chief: nil, order: order)
        XCTAssertEqual(out.topLevels.first?.id, "chief")
        XCTAssertEqual(ids(out.yours), ["mine", "yours:+1"])
    }

    func testSearchKeepsAncestors() {
        let items = order.enumerated().map { i, id in session(id, modified: Int64(1000 - i)) }
        let found = AttentionTree.matching(items, parent: { self.parents[$0] }) { $0.id == "t1" }
        XCTAssertEqual(Set(found.map(\.id)), ["t1", "tang", "chief"])
        XCTAssertTrue(AttentionTree.matches(items[0], "chi"))
        XCTAssertFalse(AttentionTree.matches(items[0], "zzz"))
    }
}

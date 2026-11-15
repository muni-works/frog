import XCTest
@testable import Frog

/// The quick-switch shortcuts' reading of the sidebar: the Nth top-level row, and next or
/// previous with wrap.
@MainActor
final class SidebarOrderTests: XCTestCase {
    private static func session(_ id: String, modified: Int64) -> SessionInfo {
        SessionInfo(
            id: id, modified: modified, created: modified, model: "m",
            firstInput: nil, title: id, end: nil,
            forkedFrom: nil, cwd: "/tmp/frog-sidebar-tests")
    }

    private static let list = [
        session("p1", modified: 900),
        session("a", modified: 800),
        session("b", modified: 700),
        session("c", modified: 600),
        session("d", modified: 500),
    ]

    func testTheNthRowIsTheNthSession() {
        XCTAssertEqual(SidebarOrder.session(at: 1, topLevels: Self.list)?.id, "p1")
        XCTAssertEqual(SidebarOrder.session(at: 3, topLevels: Self.list)?.id, "b")
    }

    func testNineIsTheLastRow() {
        XCTAssertEqual(SidebarOrder.session(at: 9, topLevels: Self.list)?.id, "d")
        XCTAssertEqual(SidebarOrder.session(at: 9, topLevels: [Self.list[0]])?.id, "p1")
    }

    func testPastTheEndThereIsNothing() {
        // Past ⌘8 there's no Nth row — but ⌘9 (the last) works whenever there is one, so only
        // an empty list leaves it without a target.
        XCTAssertNil(SidebarOrder.session(at: 6, topLevels: Self.list))
        XCTAssertNil(SidebarOrder.session(at: 0, topLevels: Self.list))
        XCTAssertNil(SidebarOrder.session(at: 9, topLevels: []))
    }

    func testNextAndPreviousWrap() {
        // On the first row, previous wraps to the last.
        XCTAssertEqual(SidebarOrder.neighbor(of: "p1", in: Self.list, step: -1)?.id, "d")
        // Stepping forward from the last wraps to the first.
        XCTAssertEqual(SidebarOrder.neighbor(of: "d", in: Self.list, step: 1)?.id, "p1")
        // In the middle, plain neighbors.
        XCTAssertEqual(SidebarOrder.neighbor(of: "b", in: Self.list, step: 1)?.id, "c")
        XCTAssertEqual(SidebarOrder.neighbor(of: "b", in: Self.list, step: -1)?.id, "a")
    }

    func testSteppingInFromOffscreen() {
        // Not on screen: next enters at the top, previous enters at the end.
        XCTAssertEqual(SidebarOrder.neighbor(of: nil, in: Self.list, step: 1)?.id, "p1")
        XCTAssertEqual(SidebarOrder.neighbor(of: nil, in: Self.list, step: -1)?.id, "d")
        XCTAssertEqual(SidebarOrder.neighbor(of: "gone", in: Self.list, step: 1)?.id, "p1")
    }

    func testAnEmptyListHasNoNeighbor() {
        XCTAssertNil(SidebarOrder.neighbor(of: nil, in: [], step: 1))
        XCTAssertNil(SidebarOrder.neighbor(of: "p1", in: [], step: -1))
    }

    func testAChildRowDoesNotCount() {
        // Nested children aren't in the top-level list the commands build; the mapping sees
        // only the rows a digit would target. A session on screen that isn't a top-level row
        // (a child, resumed on its own) still steps from its parent's neighbor.
        let parent = Self.session("parent", modified: 800)
        let child = Self.session("child", modified: 700)
        XCTAssertEqual(SidebarOrder.neighbor(of: child.id, in: [parent], step: 1)?.id, "parent")
    }
}

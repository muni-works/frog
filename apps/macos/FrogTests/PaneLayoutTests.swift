import SwiftUI
import XCTest
@testable import Frog

/// Rearranging panes: splitting beside one, moving one to another's edge, closing, and where
/// each ends up on screen.
final class PaneLayoutTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testSplittingBesideMakesARowOrColumn() {
        let row = PaneLayout.leaf(a).inserting(b, beside: a, on: .right)
        XCTAssertEqual(row, .even(.horizontal, [.leaf(a), .leaf(b)]))
        let col = PaneLayout.leaf(a).inserting(b, beside: a, on: .top)
        XCTAssertEqual(col, .even(.vertical, [.leaf(b), .leaf(a)]))
    }

    func testSplittingTheSameWayJoinsTheRow() {
        // c takes half of a's space; b keeps its own.
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)]).inserting(c, beside: a, on: .right)
        XCTAssertEqual(row, .split(.horizontal, [.leaf(a), .leaf(c), .leaf(b)], weights: [0.25, 0.25, 0.5]))
    }

    func testSplittingAcrossNests() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)]).inserting(c, beside: b, on: .bottom)
        XCTAssertEqual(grid, .even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])]))
    }

    func testRemovingCollapsesAndFlattens() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        XCTAssertEqual(grid.removing(b), .even(.horizontal, [.leaf(a), .leaf(c)]))
        XCTAssertNil(PaneLayout.leaf(a).removing(a))
    }

    func testMovingAPaneToAnotherEdge() {
        // a | (b / c): move c to a's left → c | a | b.
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        let moved = grid.removing(c)!.inserting(c, beside: a, on: .left)
        XCTAssertEqual(moved, .split(.horizontal, [.leaf(c), .leaf(a), .leaf(b)], weights: [0.25, 0.25, 0.5]))
        XCTAssertEqual(moved.leaves, [c, a, b])
    }

    func testSwapping() {
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        XCTAssertEqual(row.swapping(a, b), .even(.horizontal, [.leaf(b), .leaf(a)]))
    }

    func testDraggingADividerMovesShareBetweenNeighbors() {
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b), .leaf(c)])
        let moved = row.moving(divider: 0, at: [], to: 0.5, minimum: 0.1)
        guard case .split(_, _, let w) = moved else { return XCTFail() }
        XCTAssertEqual(w[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(w[1], 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(w[2], 1.0 / 3, accuracy: 1e-9)
        // Clamped so the neighbor keeps its minimum.
        guard case .split(_, _, let clamped) = row.moving(divider: 0, at: [], to: 0.9, minimum: 0.1) else { return XCTFail() }
        XCTAssertEqual(clamped[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(row.moving(divider: 0, at: [], to: 0.5, minimum: 0.1).equalizing(at: []), row)
    }

    func testNestedDividersHavePaths() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        let d = grid.dividers(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(d.map(\.path), [[], [1]])
        XCTAssertEqual(d[0].position, 500)
        XCTAssertEqual(d[1].position, 400)
    }

    func testFramesShareSpaceEvenly() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        let f = grid.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(f[a], CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(f[b], CGRect(x: 500, y: 0, width: 500, height: 400))
        XCTAssertEqual(f[c], CGRect(x: 500, y: 400, width: 500, height: 400))
    }
}

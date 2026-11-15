import SwiftUI
import XCTest
@testable import Frog

/// Expanding panes: a maximized pane fills the canvas and restores its layout exactly, the
/// divider's clamp lets a tool pane (a preview) go to 260 while a transcript keeps its floor,
/// and nothing to drag is left while a pane is maximized.
@MainActor
final class PaneExpandTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()
    let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: Maximize

    func testMaximizedLeafTakesTheWholeCanvas() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        let f = grid.frames(in: canvas, maximizing: b)
        XCTAssertEqual(f[b], canvas)
        XCTAssertEqual(f[a], .zero)
        XCTAssertEqual(f[c], .zero)
    }

    func testMaximizedNestedLeafTakesTheWholeCanvas() {
        // a's split nests below b's: maximizing a still fills the canvas.
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        let f = grid.frames(in: canvas, maximizing: a)
        XCTAssertEqual(f[a], canvas)
        XCTAssertEqual(f[b], .zero)
        XCTAssertEqual(f[c], .zero)
    }

    func testNoDividersWhileMaximized() {
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .even(.vertical, [.leaf(b), .leaf(c)])])
        XCTAssertEqual(grid.dividers(in: canvas, maximizing: b).count, 0)
        XCTAssertEqual(grid.dividers(in: canvas, maximizing: a).count, 0)
        XCTAssertEqual(grid.dividers(in: canvas).count, 2, "nothing maximized: dividers as usual")
    }

    func testMaximizingWithoutThePaneLeavesItAlone() {
        // A maximized id that isn't a leaf here (a different window's pane) changes nothing.
        let other = UUID()
        let grid = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        XCTAssertEqual(grid.frames(in: canvas, maximizing: other), grid.frames(in: canvas))
        XCTAssertEqual(grid.dividers(in: canvas, maximizing: other).count, grid.dividers(in: canvas).count)
    }

    // MARK: Panes model

    private func makePanes() -> (Panes, Pane, Pane, Pane) {
        let panes = Panes(Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fresh: true))
        let first = panes.items[0]
        panes.split()
        panes.split()
        return (panes, first, panes.items[1], panes.items[2])
    }

    func testMaximizeRoundTripsTheLayoutExactly() throws {
        let (panes, first, second, third) = makePanes()
        // A hand-made arrangement: first wide, then two sharing the rest.
        panes.setLayoutForTesting(.split(.horizontal, [.leaf(first.id), .even(.vertical, [.leaf(second.id), .leaf(third.id)])], weights: [0.6, 0.4]))
        let before = panes.layout

        panes.toggleMaximized(first)
        XCTAssertEqual(panes.maximized, first.id)
        // The view, not the layout: the saved layout is what restore puts back.
        XCTAssertEqual(panes.layout, before, "maximizing doesn't rewrite the layout")

        panes.toggleMaximized(first)
        XCTAssertNil(panes.maximized)
        XCTAssertEqual(panes.layout, before, "restore puts the exact layout back")
    }

    func testMaximizingAnotherPaneSavesOnlyOnceAndSwaps() {
        let (panes, first, second, _) = makePanes()
        let before = panes.layout
        panes.toggleMaximized(first)
        panes.toggleMaximized(second)
        XCTAssertEqual(panes.maximized, second.id)
        XCTAssertEqual(panes.savedLayout, before, "the original layout is still the saved one")
        panes.toggleMaximized(second)
        XCTAssertEqual(panes.layout, before)
    }

    func testClosingTheMaximizedPaneClearsIt() {
        let (panes, first, second, _) = makePanes()
        panes.toggleMaximized(first)
        panes.close(first)
        XCTAssertNil(panes.maximized)
        XCTAssertNil(panes.savedLayout)
        XCTAssertEqual(panes.layout, PaneLayout.even(.horizontal, [.leaf(second.id), .leaf(panes.items[1].id)]))
    }

    // MARK: The divider's clamp

    func testToolPaneCanReach260OnANarrowCanvas() {
        // An ~800pt two-pane window: 260pt of it is 0.325 of the pair.
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        let minimum = WorkspaceView.minToolPane / 800
        let moved = row.moving(divider: 0, at: [], to: minimum, minimum: minimum)
        guard case .split(_, _, let w) = moved else { return XCTFail() }
        XCTAssertEqual(w[0], minimum, accuracy: 1e-9)
        XCTAssertEqual(w[1], 1 - minimum, accuracy: 1e-9)
    }

    func testConversationPaneKeepsItsFloorOnANarrowCanvas() {
        // The old floor pinned both panes near even shares; now the absolute minimum is
        // capped at a quarter of the pair, so a drag can still take one pane to 3/4.
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        let minimum = WorkspaceView.minPane / 800
        let moved = row.moving(divider: 0, at: [], to: 0.05, minimum: minimum)
        guard case .split(_, _, let w) = moved else { return XCTFail() }
        XCTAssertEqual(w[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(w[1], 0.75, accuracy: 1e-9)
    }

    func testWideCanvasStillHonorsTheAbsoluteFloor() {
        // On a canvas long enough for the floor to be small, it applies as before.
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        let minimum = WorkspaceView.minPane / 2000
        let moved = row.moving(divider: 0, at: [], to: minimum, minimum: minimum)
        guard case .split(_, _, let w) = moved else { return XCTFail() }
        XCTAssertEqual(w[0], minimum, accuracy: 1e-9)
    }

    func testClampNeverExceedsEvenShareForEitherSide() {
        // From the far end, the same cap applies to the other neighbor.
        let row = PaneLayout.even(.horizontal, [.leaf(a), .leaf(b)])
        let moved = row.moving(divider: 0, at: [], to: 0.95, minimum: 0.9)
        guard case .split(_, _, let w) = moved else { return XCTFail() }
        XCTAssertEqual(w[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(w[0], 0.75, accuracy: 1e-9)
    }
}

extension Panes {
    /// Tests only: arrange the layout directly (the real paths go through split/move, which
    /// keep `items` in reading order the same way).
    func setLayoutForTesting(_ layout: PaneLayout) {
        reorderForTesting(layout)
    }
}

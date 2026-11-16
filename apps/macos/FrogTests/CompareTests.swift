import AppKit
import XCTest
@testable import Frog

/// Which screenshot the preview's then/now opens on.
@MainActor
final class CompareTests: XCTestCase {
    private let image = NSImage(size: CGSize(width: 4, height: 4))

    func testDefaultsToTheNewestUpToTheCurrentTurn() {
        let hub = PaneHub()
        for t: UInt64 in [1, 3, 5] { hub.checkpoint(image, turn: t) }
        hub.currentTurn = 4
        hub.compare()
        XCTAssertEqual(hub.comparing, 3)
        hub.currentTurn = 5
        hub.compare()
        XCTAssertEqual(hub.comparing, 5)
    }

    func testAPickedTurnWins() {
        let hub = PaneHub()
        for t: UInt64 in [1, 3] { hub.checkpoint(image, turn: t) }
        hub.currentTurn = 3
        hub.compare(1)
        XCTAssertEqual(hub.comparing, 1)
    }

    func testOpensOnTheCurrentTurnWithNoScreenshots() {
        let hub = PaneHub()
        hub.currentTurn = 7
        hub.compare()
        XCTAssertEqual(hub.comparing, 7)
        XCTAssertTrue(hub.checkpointTurns.isEmpty)
    }

    func testReplayedCheckpointLoadsFromTheSessionFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "panes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "panes/turn-2.png"))
        let hub = PaneHub()
        hub.sessionDir = dir
        hub.apply(.paneCheckpoint(turn: 2, path: "panes/turn-2.png"))
        XCTAssertEqual(hub.checkpointTurns, [2])
    }
}

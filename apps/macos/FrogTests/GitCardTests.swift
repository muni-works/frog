import AppKit
import XCTest
@testable import Frog

/// The git hover card's lifecycle (docs/design/sidebar-git/README.md §3b): the open delay, the
/// grace, the warm move between badges, pinning, and what closes it.
@MainActor
final class GitCardTests: XCTestCase {
    private var window: NSWindow!
    private var anchors: [AnchorBox] = []

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        anchors = (0..<2).map { i in
            let v = NSView(frame: NSRect(x: 200, y: 200 - CGFloat(i) * 30, width: 40, height: 16))
            window.contentView?.addSubview(v)
            let box = AnchorBox()
            box.view = v
            return box
        }
        window.orderFront(nil)
    }

    override func tearDown() {
        GitCardController.shared.close()
        window.orderOut(nil)
    }

    private func request(_ id: String) -> GitCardController.Request {
        .init(id: id, title: id, sessions: [], single: true, counts: "", open: { _ in }, refresh: {})
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRestOpensGraceClosesWarmMoves() {
        let c = GitCardController.shared
        c.close()
        spin(1.1)  // out of any warm period
        c.enterBadge(request("a"), anchor: anchors[0])
        spin(0.2)
        XCTAssertNil(c.current, "a pass of the pointer opens nothing")
        spin(0.5)
        XCTAssertEqual(c.current?.id, "a", "a 500 ms rest opens it")

        // Leaving the badge for the card within the grace keeps it.
        c.leaveBadge("a")
        spin(0.1)
        c.enterCard()
        spin(0.5)
        XCTAssertEqual(c.current?.id, "a")

        // Leaving both closes it.
        c.leaveCard()
        spin(0.5)
        XCTAssertNil(c.current)

        // Warm: the next badge opens at once.
        c.enterBadge(request("b"), anchor: anchors[1])
        spin(0.05)
        XCTAssertEqual(c.current?.id, "b")
        c.leaveBadge("b")
        spin(0.5)
        XCTAssertNil(c.current)
    }

    func testClickPinsAndOnlyAClickOrEscCloses() {
        let c = GitCardController.shared
        c.toggle(request("a"), anchor: anchors[0])
        XCTAssertEqual(c.current?.id, "a")
        XCTAssertTrue(c.pinned)
        c.leaveBadge("a")
        spin(0.5)
        XCTAssertEqual(c.current?.id, "a", "a pinned card stays when the pointer leaves")
        c.toggle(request("a"), anchor: anchors[0])
        XCTAssertNil(c.current, "a second click closes it")
    }

    func testRowGoneClosesItsCardOnly() {
        let c = GitCardController.shared
        c.toggle(request("a"), anchor: anchors[0])
        c.rowGone("b")
        XCTAssertEqual(c.current?.id, "a")
        c.rowGone("a")
        XCTAssertNil(c.current)
    }
}

import XCTest
@testable import Frog

/// The update drain reaches every live engine: the ones a window shows AND the broker's
/// background fleet (managers and workers run headless there). Missing the background
/// fleet suspended only what was on screen and let workers' turns die as crashes.
@MainActor
final class DrainFleetTests: XCTestCase {

    /// liveBackground lists only the fleet's live conversations; with no fleet it's empty
    /// and touches nothing in Library (the union with open windows happens in drainAll).
    func testLiveBackgroundStartsEmpty() {
        let b = SessionBroker()
        XCTAssertEqual(b.liveBackground.count, 0)
    }
}

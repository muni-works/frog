import XCTest
@testable import Frog

/// The sidebar's done check. It used to be permanent for any child session
/// (`depth > 0 && session.end == .complete`), so every finished worker and manager wore a green
/// check for the life of the app, visited or not (Cam: "remove the done checkmark after
/// visiting a thread"). There is no "visited" set to consult, and `Library.live` can't express
/// one — `markRead` only clears `.unread`, which a session that finished before launch never
/// was — so the check now follows what's actually knowable: a turn ending while you watch, and
/// the pointer arriving on the row.
final class RowCheckTests: XCTestCase {
    /// A turn that just ended flashes a check.
    func testAFreshFinishFlashes() {
        XCTAssertEqual(RowCheck.of(fresh: true, finished: true, hovering: false), .fresh)
    }

    /// A finished row that hasn't been looked at keeps a quiet check — so a finished worker
    /// never reads as live work.
    func testAnOldFinishKeepsAQuietCheckUntilLookedAt() {
        XCTAssertEqual(RowCheck.of(fresh: false, finished: true, hovering: false), .quiet)
    }
    /// The regression: looking ends it. This is the whole bug — the check used to survive the
    /// pointer, the click and everything else, forever.
    func testLookingAtTheRowEndsTheCheck() {
        XCTAssertEqual(RowCheck.of(fresh: false, finished: true, hovering: true), .none)
        XCTAssertEqual(RowCheck.of(fresh: true, finished: true, hovering: true), .none)
    }

    /// A session that never finished a clean turn has nothing to check off — and a failed one
    /// keeps its red, which is a state, not a receipt.
    func testOnlyACleanFinishChecks() {
        XCTAssertEqual(RowCheck.of(fresh: true, finished: false, hovering: false), .none)
        XCTAssertEqual(RowCheck.of(fresh: false, finished: false, hovering: false), .none)
    }

    /// Idle must not read as running: the glyph for a finished, seen row is still `idle`, and
    /// only `idle` shows the check. The spinner comes from `.running`, which a finished session
    /// never derives to.
    func testIdleAndRunningStayDistinct() {
        XCTAssertEqual(SessionEndGlyph.derive(live: nil, end: .complete), .idle)
        XCTAssertEqual(SessionEndGlyph.derive(live: .running, end: .complete), .running)
        XCTAssertEqual(RowCheck.of(fresh: false, finished: true, hovering: true), .none,
                       "a seen row is idle with no glyph — not a spinner")
    }
}

import XCTest
@testable import Frog

final class VerbosityTests: XCTestCase {
    /// The subtitle shows the sentence being written, or the last whole one while the next has
    /// only just begun.
    func testSubtitleShowsTheSentenceBeingWritten() {
        XCTAssertEqual(ThoughtSubtitle.current("").1, "")
        XCTAssertEqual(ThoughtSubtitle.current("Let me check the tests first").1, "Let me check the tests first")
        let begun = ThoughtSubtitle.current("I should read the README first. Then")
        XCTAssertEqual(begun.1, "I should read the README first.")
        XCTAssertEqual(begun.0, 0)
        let going = ThoughtSubtitle.current("I should read the README first. Then look at how the engine starts")
        XCTAssertEqual(going.1, "Then look at how the engine starts")
        XCTAssertEqual(going.0, 1)
        XCTAssertEqual(ThoughtSubtitle.current("A plan:\nstep one is to read the protocol").1, "step one is to read the protocol")
    }

    /// Thinking switched off before verbosity existed reads as quiet; otherwise normal.
    func testDefaultComesFromTheOldThinkingSwitch() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: Verbosity.key), d.object(forKey: "showThinking"))
        defer {
            d.set(saved.0, forKey: Verbosity.key)
            d.set(saved.1, forKey: "showThinking")
        }
        d.removeObject(forKey: Verbosity.key)
        d.set(false, forKey: "showThinking")
        XCTAssertEqual(Verbosity.standard, .quiet)
        d.removeObject(forKey: "showThinking")
        XCTAssertEqual(Verbosity.standard, .normal)
        d.set("verbose", forKey: Verbosity.key)
        XCTAssertEqual(Verbosity.standard, .verbose)
    }
}

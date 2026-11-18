import XCTest
@testable import Frog

final class VerbosityTests: XCTestCase {
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

import XCTest
@testable import Frog

/// A tool the model reached for in a chat with no folder isn't a "repeated call refused".
final class ToolResultWordsTests: XCTestCase {
    func testErrorBadges() {
        XCTAssertEqual(ToolResultWords.errorLabel("refused: repeated identical call"), "Repeated call refused")
        XCTAssertEqual(ToolResultWords.errorLabel("no folder: answer in chat"), "No folder open")
        XCTAssertEqual(ToolResultWords.errorLabel("not an available tool"), "Not available")
        // An older engine's wording for the same thing.
        XCTAssertEqual(ToolResultWords.errorLabel("refused: not an available tool"), "Not available")
        XCTAssertEqual(ToolResultWords.errorLabel("exit 1"), "Failed")
        XCTAssertEqual(ToolResultWords.errorLabel(nil), "Failed")
    }
}

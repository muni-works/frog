import XCTest
@testable import Frog

/// A row's ask reads as one plain question under the needs-you dot (the web's ask.test.ts).
final class AskPhraseTests: XCTestCase {
    func testAsksReadAsPlainQuestions() {
        XCTAssertEqual(AskPhrase.line(name: "Bash", arg: "cargo test -q\nmore"), "Run cargo test -q?")
        XCTAssertEqual(AskPhrase.line(name: "Edit", arg: "src/fetch.ts"), "Edit fetch.ts?")
        XCTAssertEqual(AskPhrase.line(name: "WebFetch", arg: "https://docs.rs/x"), "Open docs.rs?")
        XCTAssertEqual(AskPhrase.line(name: "Mcp", arg: ""), "Allow Mcp?")
    }
}

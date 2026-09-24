import XCTest
@testable import Kiln

/// How dictated words land in the composer, without a microphone.
final class DictationTests: XCTestCase {
    func testGuessesAreReplacedAndFinalsAccumulate() {
        var t = DictationTranscript()
        t.apply("hel", isFinal: false)
        t.apply("hello there", isFinal: false)
        XCTAssertEqual(t.parts.final, "")
        XCTAssertEqual(t.parts.volatile, "hello there")
        t.apply("Hello there.", isFinal: true)
        t.apply(" how", isFinal: false)
        XCTAssertEqual(t.parts.final, "Hello there.")
        XCTAssertEqual(t.parts.volatile, " how")
        t.apply(" How are you?", isFinal: true)
        XCTAssertEqual(t.parts.final + t.parts.volatile, "Hello there. How are you?")
        XCTAssertEqual(t.parts.volatile, "")
    }

    func testPaddingKeepsWordsApart() {
        let a = unichar(UInt8(ascii: "a")), space = unichar(UInt8(ascii: " "))
        XCTAssertEqual(DictationTranscript.padding(before: nil, after: nil, empty: false).lead, "")
        XCTAssertEqual(DictationTranscript.padding(before: a, after: nil, empty: false).lead, " ")
        XCTAssertEqual(DictationTranscript.padding(before: space, after: a, empty: false).lead, "")
        XCTAssertEqual(DictationTranscript.padding(before: space, after: a, empty: false).trail, " ")
        XCTAssertEqual(DictationTranscript.padding(before: a, after: a, empty: true).lead, "")
    }

    func testEditsMoveOrReleaseTheDictatedRange() {
        let r = NSRange(location: 10, length: 5)
        // Typing before it pushes it along; after it leaves it alone.
        XCTAssertEqual(DictationTranscript.shift(r, byEdit: NSRange(location: 2, length: 0), replacement: 3), NSRange(location: 13, length: 5))
        XCTAssertEqual(DictationTranscript.shift(r, byEdit: NSRange(location: 0, length: 4), replacement: 0), NSRange(location: 6, length: 5))
        XCTAssertEqual(DictationTranscript.shift(r, byEdit: NSRange(location: 15, length: 0), replacement: 1), r)
        // Editing inside it hands it to the person.
        XCTAssertNil(DictationTranscript.shift(r, byEdit: NSRange(location: 12, length: 1), replacement: 0))
        XCTAssertNil(DictationTranscript.shift(r, byEdit: NSRange(location: 8, length: 4), replacement: 0))
        // Typing at an empty anchor keeps dictation after what was typed.
        XCTAssertEqual(DictationTranscript.shift(NSRange(location: 4, length: 0), byEdit: NSRange(location: 4, length: 0), replacement: 2), NSRange(location: 6, length: 0))
    }
}

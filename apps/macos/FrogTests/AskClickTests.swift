import XCTest
@testable import Frog

/// The Ask card's arity, as the person decides it (the web's ask.test.ts): the model's `multi`
/// is a starting guess, a plain click on a single-choice card answers at once, and a click while
/// a draft is typed or after "Pick several" picks instead of answering.
final class AskClickTests: XCTestCase {
    func testAPlainClickOnASingleChoiceCardAnswersAtOnce() {
        XCTAssertEqual(
            AskClick.click(multi: false, picking: false, drafting: false, label: "Truncate"),
            .answer("Truncate")
        )
    }

    func testAMultiCardTogglesInsteadOfAnswering() {
        XCTAssertEqual(
            AskClick.click(multi: true, picking: false, drafting: false, label: "Truncate"),
            .toggle(picking: false)
        )
    }

    func testTypingFirstMakesTheClickPartOfOneAnswer() {
        // The bug: on a single-choice card with allow_other, a click answered immediately, so
        // anything typed next to it could never be part of the answer.
        XCTAssertEqual(
            AskClick.click(multi: false, picking: false, drafting: true, label: "Truncate"),
            .toggle(picking: true)
        )
    }

    func testOncePickingFurtherClicksKeepToggling() {
        XCTAssertEqual(
            AskClick.click(multi: false, picking: true, drafting: false, label: "Checksum"),
            .toggle(picking: true)
        )
        // Back to "Pick one": a click answers again rather than silently sending what was picked.
        XCTAssertEqual(
            AskClick.click(multi: false, picking: false, drafting: false, label: "Checksum"),
            .answer("Checksum")
        )
    }

    func testAMultiQuestionIsWideWhicheverWayThePersonGotThere() {
        XCTAssertEqual(
            AskClick.click(multi: true, picking: false, drafting: true, label: "a"),
            .toggle(picking: false)
        )
    }
}

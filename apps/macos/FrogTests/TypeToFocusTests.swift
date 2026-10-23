import AppKit
import XCTest
@testable import Frog

/// Type-to-focus's decision list — what the key monitor asks before pre-focusing the
/// composer. The wiring itself (promote the composer, let the event deliver itself) needs a
/// real key window, so that's on the manual checklist instead.
@MainActor
final class TypeToFocusTests: XCTestCase {
    private func decide(
        _ chars: String?, _ modifiers: NSEvent.ModifierFlags = [],
        isKeyWindow: Bool = true, editing: Bool = false, canFocusComposer: Bool = true
    ) -> TypeToFocus.Decision {
        TypeToFocus.decide(
            TypeToFocus.Event(characters: chars, modifiers: modifiers),
            isKeyWindow: isKeyWindow, editing: editing, canFocusComposer: canFocusComposer
        )
    }

    func testPlainCharactersCompose() {
        XCTAssertEqual(decide("a"), .compose(write: "a"))
        XCTAssertEqual(decide("Z"), .compose(write: "Z")) // ⇧-shifted capitals are text
        XCTAssertEqual(decide("@"), .compose(write: "@"))
        XCTAssertEqual(decide("("), .compose(write: "("))
        XCTAssertEqual(decide("5", [.numericPad]), .compose(write: "5")) // keypad digits
    }

    func testModifierKeysPass() {
        // ⌘ ⌃ ⌥ mean shortcuts or compositions, not characters to type.
        XCTAssertEqual(decide("a", [.command]), .pass)
        XCTAssertEqual(decide("a", [.control]), .pass)
        XCTAssertEqual(decide("a", [.option]), .pass)
        XCTAssertEqual(decide("a", [.command, .shift]), .pass)
        XCTAssertEqual(decide("a", [.shift]), .compose(write: "a"))
        XCTAssertEqual(decide("a", [.capsLock]), .compose(write: "a"))
    }

    func testNonTextKeysPass() {
        XCTAssertEqual(decide(" "), .pass) // space: scroll views page on it
        XCTAssertEqual(decide("\r"), .pass) // return
        XCTAssertEqual(decide("\t"), .pass) // tab
        XCTAssertEqual(decide("\u{1B}"), .pass) // escape
        XCTAssertEqual(decide("\u{7F}"), .pass) // delete
        XCTAssertEqual(decide("\u{1}"), .pass) // ⌃A arrives as a control character
        XCTAssertEqual(decide(nil), .pass) // flags-changed: no characters at all
        XCTAssertEqual(decide(""), .pass)
        // Arrows, F-keys and friends arrive as private-use scalars.
        XCTAssertEqual(decide("\u{F700}"), .pass) // up arrow
        XCTAssertEqual(decide("\u{F704}"), .pass) // F1
    }

    func testWindowAndFocusGates() {
        XCTAssertEqual(decide("a", isKeyWindow: false), .pass) // behind another window
        XCTAssertEqual(decide("a", editing: true), .pass) // the composer or a field is focused
        XCTAssertEqual(decide("a", canFocusComposer: false), .pass) // a race, no conversation
    }

    func testPrintableScalars() {
        XCTAssertTrue(TypeToFocus.isPrintable("é".unicodeScalars.first!))
        XCTAssertTrue(TypeToFocus.isPrintable("Ω".unicodeScalars.first!))
        XCTAssertTrue(TypeToFocus.isPrintable("日".unicodeScalars.first!))
        XCTAssertFalse(TypeToFocus.isPrintable("\u{7F}".unicodeScalars.first!))
        XCTAssertFalse(TypeToFocus.isPrintable("\u{9F}".unicodeScalars.first!)) // C1 controls
        XCTAssertFalse(TypeToFocus.isPrintable("\u{F702}".unicodeScalars.first!)) // left arrow
        XCTAssertFalse(TypeToFocus.isPrintable(UnicodeScalar(0x1B)!)) // escape
    }

    func testEditingViews() {
        XCTAssertTrue(TypeToFocus.isEditing(NSTextView())) // the composer, every field editor
        XCTAssertTrue(TypeToFocus.isEditing(NSTextField())) // fields, before their editor starts
        XCTAssertTrue(TypeToFocus.isEditing(TerminalGridView())) // the shell owns its keys
        XCTAssertFalse(TypeToFocus.isEditing(NSView())) // a canvas or button holds nothing
        XCTAssertFalse(TypeToFocus.isEditing(nil)) // the window itself
    }
}

/// One key, one scalar. A precomposed character (é from a French layout) is text; a
/// multi-scalar string (a decomposed accent, a burst) isn't one typed key. Nothing is
/// inserted either way: the wiring only focuses, so IME input arrives untouched.
@MainActor
final class TypeToFocusSequenceTests: XCTestCase {
    func testPrecomposedCharacterComposes() {
        XCTAssertEqual(
            TypeToFocus.decide(
                TypeToFocus.Event(characters: "é"),
                isKeyWindow: true, editing: false, canFocusComposer: true
            ),
            .compose(write: "é")
        )
    }

    func testMultiScalarStringsPass() {
        for s in ["e\u{301}", "ab"] {
            XCTAssertEqual(
                TypeToFocus.decide(
                    TypeToFocus.Event(characters: s, modifiers: []),
                    isKeyWindow: true, editing: false, canFocusComposer: true
                ),
                .pass
            )
        }
    }
}

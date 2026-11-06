import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Typing fast into the composer while SwiftUI writes the binding back or rebuilds the field must
/// never move the caret: a reset to 0 put the first characters typed after everything typed later.
@MainActor
final class ComposerCaretTests: XCTestCase {
    @Observable final class Model {
        var text = ""
        var tick = 0
    }

    struct Box: View {
        @Bindable var model: Model
        @State var height: CGFloat = 22
        let controller: ComposerController
        var body: some View {
            let _ = model.tick // a parent re-render on demand
            ComposerTextView(text: $model.text, height: $height, controller: controller, onSubmit: {}, onEscape: { false })
                .frame(width: 500, height: 120)
        }
    }

    private let prompt = "Write a Rust function that returns the nth Fibonacci number iteratively, with a short doc comment and two unit tests."

    private func pump(_ s: TimeInterval = 0.01) {
        RunLoop.main.run(until: Date().addingTimeInterval(s))
    }

    private func host(_ model: Model, _ controller: ComposerController) -> (NSWindow, NSHostingView<Box>) {
        let host = NSHostingView(rootView: Box(model: model, controller: controller))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 140)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        return (w, host)
    }

    private func type(_ s: Substring, into controller: ComposerController, between: () -> Void = {}) {
        for c in s {
            controller.textView?.insertText(String(c), replacementRange: controller.textView!.selectedRange())
            between()
        }
    }

    private func assertTyped(_ model: Model, _ controller: ComposerController, file: StaticString = #filePath, line: UInt = #line) {
        let tv = controller.textView!
        XCTAssertEqual(tv.string, prompt, file: file, line: line)
        XCTAssertEqual(model.text, prompt, file: file, line: line)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: (prompt as NSString).length, length: 0), file: file, line: line)
    }

    /// Binding writes and parent re-renders landing between quick insertions at the end.
    func testQuickTypingSurvivesBindingEchoesAndRerenders() {
        let model = Model(), controller = ComposerController()
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        type(prompt[...], into: controller) {
            model.text = model.text // an echo of what's typed
            model.tick += 1
            host.layoutSubtreeIfNeeded()
            pump(0.001)
        }
        assertTyped(model, controller)
    }

    /// The new-chat path: the composer is replaced mid-typing, its draft saved on the way out
    /// (the text view already gone) and restored into the one that takes over. Typing goes on at
    /// the end, not ahead of the first 16 characters.
    func testDraftHandedOverMidTypingKeepsCaretAtEnd() {
        let split = prompt.index(prompt.startIndex, offsetBy: 16)
        let typed = String(prompt[..<split])
        let cursor = ComposerView.draftCursor(nil, text: typed)
        let model = Model(), controller = ComposerController()
        // restoreDraft runs on appear: the cursor may be asked for before the text view exists.
        model.text = typed
        controller.select(NSRange(location: min(cursor, typed.utf16.count), length: 0))
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        type(prompt[split...], into: controller) {
            model.tick += 1
            host.layoutSubtreeIfNeeded()
            pump(0.001)
        }
        assertTyped(model, controller)
    }

    /// The field made with text already in it (a composer rebuilt mid-typing, a restored draft):
    /// the caret starts after that text, so what's typed next follows it.
    func testFieldRebuiltMidTypingKeepsCaretAtEnd() {
        let split = prompt.index(prompt.startIndex, offsetBy: 16)
        let model = Model(), controller = ComposerController()
        model.text = String(prompt[..<split])
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        type(prompt[split...], into: controller) {
            model.tick += 1
            host.layoutSubtreeIfNeeded()
            pump(0.001)
        }
        assertTyped(model, controller)
    }

    /// A draft's cursor asked for before the text view exists (restored on appear) still lands.
    func testSelectionBeforeTheViewExistsIsApplied() {
        let model = Model(), controller = ComposerController()
        model.text = "hello world"
        controller.select(NSRange(location: 5, length: 0))
        let (w, _) = host(model, controller)
        defer { w.close() }
        XCTAssertEqual(controller.textView?.selectedRange(), NSRange(location: 5, length: 0))
    }

    /// Marked text (IME) isn't torn out by a binding write mid-composition.
    func testBindingWriteWaitsForMarkedText() {
        let model = Model(), controller = ComposerController()
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        let tv = controller.textView!
        tv.insertText("a", replacementRange: tv.selectedRange())
        tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        model.text = "something else"
        host.layoutSubtreeIfNeeded()
        pump(0.02)
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertEqual(tv.string, "a´")
    }
}

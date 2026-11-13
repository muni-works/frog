import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The field grows with what's typed, scrolls past its cap, and comes back to one line when the
/// draft is sent (the binding cleared) — including from the scrolled state.
@MainActor
final class ComposerHeightTests: XCTestCase {
    @Observable final class Model {
        var text = ""
        var height: CGFloat = 22
    }

    struct Box: View {
        @Bindable var model: Model
        let controller: ComposerController
        var body: some View {
            ComposerTextView(text: $model.text, height: $model.height, controller: controller, onSubmit: {}, onEscape: { false })
                .frame(height: model.height)
                .frame(width: 400)
        }
    }

    private func pump(_ s: TimeInterval = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func host(_ model: Model, _ controller: ComposerController) -> (NSWindow, NSHostingView<Box>) {
        let host = NSHostingView(rootView: Box(model: model, controller: controller))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        pump(0.1)
        return (w, host)
    }

    private func type(_ lines: Int, into tv: NSTextView) {
        for line in 0..<lines {
            tv.insertText("line \(line) of a draft that is going to be sent\n", replacementRange: tv.selectedRange())
        }
    }

    /// A few wrapped lines grow the field; sending puts it back to one line.
    func testHeightReturnsToOneLineAfterSending() {
        let model = Model(), controller = ComposerController()
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        let tv = controller.textView!
        type(4, into: tv)
        host.layoutSubtreeIfNeeded()
        pump(0.1)
        XCTAssertGreaterThan(model.height, 60, "a wrapped draft grows the field")

        model.text = ""
        host.layoutSubtreeIfNeeded()
        pump(0.1)
        XCTAssertEqual(model.height, 22, accuracy: 0.5, "an empty field is one line again")
        XCTAssertEqual(tv.string, "")
    }

    /// Past the cap the field scrolls; sending from there still brings it back to one line.
    func testHeightReturnsToOneLineAfterSendingFromTheScrolledState() {
        let model = Model(), controller = ComposerController()
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        let tv = controller.textView!
        type(30, into: tv)
        host.layoutSubtreeIfNeeded()
        pump(0.15)
        XCTAssertEqual(model.height, 180, accuracy: 1, "a long draft stops at the cap")

        // It scrolled to the end of what was typed, as it does while typing.
        if let scroll = tv.enclosingScrollView { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }

        model.text = ""
        host.layoutSubtreeIfNeeded()
        pump(0.15)
        XCTAssertEqual(model.height, 22, accuracy: 0.5, "an empty field is one line again, scrolled or not")
    }

    /// The same, clearing from inside the text view (select all, delete).
    func testHeightReturnsToOneLineWhenTypedTextIsCleared() {
        let model = Model(), controller = ComposerController()
        let (w, host) = host(model, controller)
        defer { w.close() }
        controller.focus()
        let tv = controller.textView!
        type(30, into: tv)
        host.layoutSubtreeIfNeeded()
        pump(0.15)
        XCTAssertEqual(model.height, 180, accuracy: 1)

        tv.selectAll(nil)
        tv.insertText("", replacementRange: tv.selectedRange())
        host.layoutSubtreeIfNeeded()
        pump(0.15)
        XCTAssertEqual(model.height, 22, accuracy: 0.5)
    }
}

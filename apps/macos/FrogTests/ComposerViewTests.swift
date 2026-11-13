import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The real composer, hosted, driven the way a person drives it: type into the field, press
/// Return. The field must come back to one line when the message goes.
@MainActor
final class ComposerViewTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let sized = AnyView(view.frame(width: 820))
        let host = NSHostingView(rootView: sized)
        host.frame = CGRect(x: 0, y: 0, width: 820, height: host.fittingSize.height)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        pump(0.25)
        return (w, host)
    }

    private func composer() throws -> (Workspace, Conversation) {
        let ws = Workspace(folder: URL(fileURLWithPath: "/tmp/frog-composer-tests"), fresh: true)
        return (ws, try XCTUnwrap(ws.conversation))
    }

    /// The height of the field itself (the box the text sits in), not the whole composer: a sent
    /// message adds a turn to the conversation, which the composer's own height mustn't count.
    private func fieldHeight(_ host: NSHostingView<AnyView>) -> CGFloat {
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        guard let tv = Self.textView(in: host), let scroll = tv.enclosingScrollView else { return 0 }
        return scroll.frame.height
    }

    /// Type a draft that fills the field to its cap, press Return, and the composer is one line
    /// tall again.
    func testReturnAfterALongDraftLeavesOneLine() throws {
        let (ws, c) = try composer()
        let (w, host) = host(ComposerView(workspace: ws, conversation: c))
        defer { w.close() }
        pump(0.3)
        let resting = fieldHeight(host)

        let tv = try XCTUnwrap(Self.textView(in: host))
        for line in 0..<30 {
            tv.insertText("line \(line) of a draft that is going to be sent\n", replacementRange: tv.selectedRange())
        }
        pump(0.3)
        XCTAssertGreaterThan(fieldHeight(host), resting + 40, "a long draft grows the field")

        // Return, as the field handles it: AppKit asks the delegate, which calls onSubmit.
        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.4)

        XCTAssertEqual(tv.string, "", "the field cleared")
        XCTAssertEqual(fieldHeight(host), resting, accuracy: 2, "the field is one line tall again")
    }

    /// Before the first message the location picker is there ("This Mac"), so a new conversation
    /// can be pointed at a Frog Cloud repo — signed out too: the chip decides where a session
    /// runs either way.
    func testNewConversationOffersTheLocationPicker() async throws {
        let had = CloudAccount.keyProvider
        CloudAccount.keyProvider = { nil }   // signed out: the picker's still there ("This Mac")
        defer { CloudAccount.keyProvider = had }
        await CloudAccount.shared.reloadKey()
        let (ws, c) = try composer()
        let (w, host) = host(ComposerView(workspace: ws, conversation: c))
        defer { w.close() }
        pump(0.3)
        let labels = await Self.labels(in: host)
        XCTAssertTrue(labels.contains { $0.contains("This Mac") },
                      "the composer offers where the conversation runs; saw \(labels)")
    }

    /// Every accessibility label in the tree, depth-first: what a person reads as the chip's
    /// text (a Menu's label is its content description).
    private static func labels(in view: NSView) async -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let label = v.accessibilityLabel(), !label.isEmpty { out.append(label) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return out
    }

    private static func textView(in host: NSView) -> NSTextView? {
        if let tv = host as? NSTextView { return tv }
        for sub in host.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }
}

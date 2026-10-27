import AppKit
import XCTest
@testable import Frog

/// The ink reveal (see `InkReveal`): a slow stream inks in a few characters a frame and the
/// fading list stays capped; a fast stream (or Reduce Motion) skips the ink and text appears
/// as it arrives. The streaming benchmark never reaches the ink path — its whole rows arrive
/// within a frame — so this covers it.
@MainActor
final class InkRevealTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func view() -> MessageTextView {
        let v = MessageTextView(usingTextLayoutManager: false)
        v.textContainer?.lineFragmentPadding = 0
        v.drawsBackground = false
        v.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        let window = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = v
        window.orderFront(nil)
        return v
    }

    /// No hidden tail or unsettled fade left: every character has no temporary color.
    private func settled(_ v: MessageTextView) -> Bool {
        guard let layout = v.layoutManager, let storage = v.textStorage else { return false }
        let length = storage.length
        guard length > 0 else { return true }
        // The temporary attribute spans the whole storage or not at all, by how it's applied.
        let attrs = layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
        return attrs[.foregroundColor] == nil
    }

    func testSlowStreamInksInAndSettles() {
        let v = view()
        defer { v.window?.close() }
        v.reveal.streaming = true
        TranscriptProbe.reset()
        // A sentence every 0.1 s: ~700 characters a second, inked rather than skipped.
        let sentence = "The parser keeps offsets stable while the tail carries pending bytes. "
        let text = String(repeating: sentence, count: 10)
        var at = text.startIndex
        while at < text.endIndex {
            let next = text.index(at, offsetBy: sentence.count, limitedBy: text.endIndex) ?? text.endIndex
            v.show(Markdown.parse(String(text[at..<next])))
            at = next
            pump(0.1)
        }
        let length = (v.textStorage?.string ?? "").count
        // CI (`TestRunner.isCI`): a runner's virtual display ticks the display link late and
        // unevenly, so the pen gets up to 5 s to catch up and the fade up to 5 s to settle,
        // polled. Locally: caught up on the last chunk's frame, settled 0.7 s later, as written.
        if TestRunner.isCI {
            let deadline = Date().addingTimeInterval(5)
            while v.reveal.revealed < length, Date() < deadline { pump(0.02) }
        }
        XCTAssertEqual(v.reveal.revealed, length, "the pen never caught up")
        pump(0.7)
        if TestRunner.isCI {
            let deadline = Date().addingTimeInterval(5)
            while !settled(v), Date() < deadline { pump(0.05) }
        }
        XCTAssertGreaterThan(TranscriptProbe.inkStyles, 0, "no ink styling ran")
        // Each character is painted at most its fade's steps (plus the full-window pass when its
        // chunk arrived), never a whole-body restyle per frame.
        XCTAssertLessThan(TranscriptProbe.inkStyledChars, 12 * length,
                          "\(TranscriptProbe.inkStyledChars) char-paints for \(length) characters")
        XCTAssertTrue(settled(v), "temporary styling left over after the ink settled")
    }

    func testFastStreamSkipsTheInk() {
        let v = view()
        defer { v.window?.close() }
        v.reveal.streaming = true
        TranscriptProbe.reset()
        // Several paragraphs at once, as a fast burst arrives: text appears as it comes.
        v.show(Markdown.parse(String(repeating: "A dense paragraph of code and notes. ", count: 80)))
        pump(0.05)
        XCTAssertEqual(v.reveal.revealed, (v.textStorage?.string ?? "").count, "fast text should simply appear")
        XCTAssertEqual(TranscriptProbe.inkStyles, 0, "the ink shouldn't restyle a fast stream")
        XCTAssertTrue(settled(v), "temporary styling left over on a skipped stream")
    }
}

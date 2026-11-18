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

    /// Spin the run loop until `condition` holds or `timeout` passes. The pen runs up to
    /// `InkReveal.lagStreaming` behind arrival by design and moves on the display's frames, so
    /// a fixed pause after the last chunk is a guess at how many frames came: on a busy machine
    /// fewer do, and the assertion raced the pen instead of checking that it gets there.
    @discardableResult
    private func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.02)
        }
        return condition()
    }

    private func view() -> MessageTextView {
        let v = MessageTextView(usingTextLayoutManager: false)
        v.textContainer?.lineFragmentPadding = 0
        v.drawsBackground = false
        v.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        let window = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = v
        window.orderInForTest()
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

    func testSlowStreamInksInAndSettles() throws {
        // CI (`TestRunner.isCI`): skipped. The ink runs on the window's display link, and a
        // runner VM's virtual display doesn't drive it like a Mac's: it failed on every CI try
        // (3 runs, 3 iterations each, even with 5 s polled waits) while passing locally. Run it
        // on a Mac; locally every assertion below holds as written.
        try XCTSkipIf(TestRunner.isCI, "display-link animation; not measurable on a CI runner's virtual display")
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
        wait(timeout: 3) { v.reveal.revealed == length }
        XCTAssertEqual(v.reveal.revealed, length, "the pen never caught up")
        // The last run fades for `InkReveal.inkTime` once revealed; wait for it rather than for
        // a guessed number of frames.
        wait(timeout: 3) { self.settled(v) }
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

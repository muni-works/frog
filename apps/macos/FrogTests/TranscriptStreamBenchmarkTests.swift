import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The streaming benchmark: one long agentic turn (500 rows: short answers between tool calls,
/// a third of them edits with diffs, so the inline file-changes strip grows as it goes) streamed
/// as fast as events can be ingested into the real transcript in a window, one frame per row.
///
/// Asserts, per row:
///  (a) no blank frames: the scroll view's visible rect lies within its laid-out document, and
///      (every 25th row, and at the end) the visible area actually has ink in it, by pixels;
///  (b) no full-transcript relayout per row: row bodies built (`TranscriptProbe.rowBodies`,
///      `ActivityLine` + `ItemView`) stay linear in rows. A relayout of the whole turn per insert
///      builds every row again each time: rows²/2 ≈ 125k bodies for 500 rows. The budget is
///      8 per row (the inserted row, its re-render as it finishes, the live tail);
///      (b′) the same for `TurnView` bodies (`TranscriptProbe.turnBodies`), which before the
///      equatable row ran 254× per streamed row — a delta re-evaluated every mounted turn.
///  (c) the view stays anchored to the bottom (within 24 pt, the transcript's own "at bottom");
///  (d) the whole stream renders within a wall-clock budget (`budget`, below): one frame of the
///      real layout per row, at 60 Hz a 500-row turn must keep up with a stream.
///
///     xcodebuild test ... -only-testing:FrogTests/TranscriptStreamBenchmarkTests
///
/// Prints `bench:` lines with the numbers.
@MainActor
final class TranscriptStreamBenchmarkTests: XCTestCase {
    /// Rows, and the wall-clock budget for streaming and rendering all of them, with room for a
    /// loaded CI machine. Measured ~21 s on an M-series Mac (debug build): ~8 s is the fixed
    /// run-loop pump floor (a 16 ms frame per row), ~2 s the pixel checks, ~11 s the real
    /// ingest+layout+render work (~22 ms a row, release well under a 60 Hz frame).
    private static let rows = Int(ProcessInfo.processInfo.environment["FROG_BENCH_ROWS"] ?? "") ?? 500
    private static let budget: TimeInterval = 30

    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        clock += 7
        let line = #"{"seq":\#(seq),"session":"bench","created":\#(clock),"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func pump(_ seconds: TimeInterval = 0.016) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Sampling stride for the ink check: `colorAt` is slow, and this is a benchmark.
    private static let inkStride = 4

    private func outerScroll(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = outerScroll(in: sub) { return s } }
        return nil
    }

    /// One row's events: an answer streamed in pieces, or a tool call (every third an edit with
    /// a diff; a new file every other edit, so the changes strip gains a chip).
    private func row(_ r: Int, into c: Conversation) {
        if r % 2 == 0 {
            let id = "msg-\(r)"
            let text = "Step \(r / 2): checked the parser against the fixtures and moved on to the next file, with notes."
            send(c, #""item_started","id":"\#(id)","kind":{"type":"message"}"#)
            var at = text.startIndex
            while at < text.endIndex {
                let next = text.index(at, offsetBy: 24, limitedBy: text.endIndex) ?? text.endIndex
                send(c, #""item_delta","id":"\#(id)","delta":{"type":"text","text":\#(Self.json(String(text[at..<next])))}"#)
                at = next
            }
            send(c, #""item_completed","id":"\#(id)","item":{"type":"message","text":\#(Self.json(text))}"#)
            return
        }
        let id = "tool-\(r)"
        switch (r / 2) % 3 {
        case 0:
            let path = "src/file\(r / 12).swift"
            send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Edit","arg":"\#(path)"}"#)
            send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Edit","arg":"\#(path)","input":{"file_path":"\#(path)"},"outcome":"ok","output":"ok","display":null,"diff":{"path":"\#(path)","created":false,"added":3,"removed":1,"hunks":[{"lines":[{"kind":"add","old":null,"new":\#(r),"text":"let x = \#(r)"}]}]}}"#)
        case 1:
            send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Read","arg":"src/read\#(r).swift"}"#)
            send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Read","arg":"src/read\#(r).swift","input":{"file_path":"src/read\#(r).swift"},"outcome":"ok","output":"1 line","display":null}"#)
        default:
            send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
            send(c, #""item_delta","id":"\#(id)","delta":{"type":"output","text":"ok\n"}"#)
            send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Bash","arg":"cargo test","input":{"command":"cargo test"},"outcome":"ok","output":"ok","display":null}"#)
        }
    }

    /// Content below the visible rect, in points (the transcript's own measure of "at bottom").
    private func below(_ scroll: NSScrollView) -> CGFloat {
        guard let doc = scroll.documentView else { return 0 }
        let visible = scroll.documentVisibleRect
        let inset = scroll.contentInsets.bottom
        return doc.isFlipped ? doc.bounds.height - (visible.maxY - inset) : visible.minY + inset
    }

    /// The visible rect lies over laid-out content (not past either end of the document).
    private func overContent(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return false }
        let overlap = scroll.documentVisibleRect.intersection(doc.bounds)
        return overlap.height >= min(doc.bounds.height, scroll.documentVisibleRect.height) * 0.5
    }

    /// The fraction of the transcript's visible area (between its top and bottom fades, where
    /// the pill would be) with ink, by alpha: the window layers draw over a clear backing, so a
    /// blank frame is transparent pixels, and the most common *color* here is transparent black
    /// even on a full page of text.
    private func ink(_ scroll: NSScrollView, in host: NSView) -> Double {
        var rect = scroll.convert(scroll.bounds, to: host)
        rect = rect.insetBy(dx: 0, dy: 70)
        guard rect.height > 20, let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return 0 }
        host.cacheDisplay(in: rect, to: rep)
        var inked = 0, samples = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: Self.inkStride) {
            for x in stride(from: 0, to: rep.pixelsWide, by: Self.inkStride) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                if c.alphaComponent > 0.5 { inked += 1 }
            }
        }
        guard samples > 0 else { return 0 }
        return Double(inked) / Double(samples)
    }

    func testStreaming500RowsStaysDrawnAnchoredAndIncremental() throws {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "bench")
        let view = TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .frame(width: 900, height: 700)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        send(c, #""turn_started","turn":1,"input":\#(Self.json("Refactor the parser, file by file, and run the tests as you go"))"#)
        send(c, #""progress","label":"thinking""#)
        pump(0.2)
        let scroll = try XCTUnwrap(outerScroll(in: host), "no scroll view")
        TranscriptProbe.reset()

        var blankGeometry: [Int] = [], blankPixels: [Int] = [], unanchored: [Int] = []
        var worstBelow: CGFloat = 0
        var ingestTime: TimeInterval = 0, frameTime: TimeInterval = 0
        let started = Date()
        for r in 0..<Self.rows {
            var t = Date()
            row(r, into: c)
            ingestTime += -t.timeIntervalSinceNow
            t = Date()
            pump()
            frameTime += -t.timeIntervalSinceNow
            if !overContent(scroll) { blankGeometry.append(r) }
            // Anchoring is judged once the content overflows the view.
            if let doc = scroll.documentView, doc.bounds.height > scroll.documentVisibleRect.height {
                let b = below(scroll)
                worstBelow = max(worstBelow, b)
                if b > 24 { unanchored.append(r) }
            }
                       if r % 50 == 49, ink(scroll, in: host) < 0.002 { blankPixels.append(r) }
        }
        let streamed = Date().timeIntervalSince(started)
        send(c, #""turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"context_tokens":2377,"input_tokens":13861,"output_tokens":470,"model_calls":250,"tokens_per_sec":28.4}"#)
        send(c, #""idle""#)
        pump(0.3)
        let total = Date().timeIntervalSince(started)
        let finalInk = ink(scroll, in: host)

        let rows = Self.rows
        let rowBodies = TranscriptProbe.rowBodies
        print("bench: \(rows) rows in \(String(format: "%.2f", streamed))s stream, \(String(format: "%.2f", total))s total, \(Int(Double(rows) / streamed)) rows/s")
        print("bench: ingest \(String(format: "%.2f", ingestTime))s, frame \(String(format: "%.2f", frameTime))s")
        print("bench: row bodies \(rowBodies) (\(String(format: "%.1f", Double(rowBodies) / Double(rows)))/row), turn bodies \(TranscriptProbe.turnBodies), follows \(TranscriptProbe.follows)")
        print("bench: ink styles \(TranscriptProbe.inkStyles), chars \(TranscriptProbe.inkStyledChars)")
        print("bench: blank(geometry) \(blankGeometry.count) \(blankGeometry.prefix(8)), blank(pixels) \(blankPixels.count) \(blankPixels.prefix(8)), final ink \(String(format: "%.4f", finalInk))")
        print("bench: unanchored \(unanchored.count) \(unanchored.prefix(8)), worst below \(Int(worstBelow)) pt")

        XCTAssertEqual(c.turns.first?.items.count, rows)
        TranscriptBenchDebug.dump(host, name: "bench-final.png")
        XCTAssertTrue(blankGeometry.isEmpty, "visible rect left the content at rows \(blankGeometry.prefix(20))")
        XCTAssertTrue(blankPixels.isEmpty, "blank frames at rows \(blankPixels.prefix(20))")
        XCTAssertGreaterThan(finalInk, 0.002, "blank after the stream")
        XCTAssertLessThanOrEqual(rowBodies, rows * 8, "row bodies grew faster than rows: a full relayout per insert")
        // Every mounted turn's body per streamed row was the old shape (measured 254/row,
        // 126,674 for 500 rows, before TurnView was equatable and the live turn's segments
        // cached): a streamed delta must invalidate ONE row, not every mounted turn. Bounded
        // small — the inserted row, its re-render as it finishes, the live tail — like row
        // bodies, so a regression back to the quadratic fails here.
        let turnBodies = TranscriptProbe.turnBodies
        XCTAssertLessThanOrEqual(turnBodies, rows * 8, "turn bodies grew faster than rows: every mounted turn rebuilt per streamed row")
        XCTAssertTrue(unanchored.isEmpty, "left the bottom at rows \(unanchored.prefix(20)) (worst \(worstBelow) pt)")
        XCTAssertLessThan(below(scroll), 24, "not at the bottom after the stream")
        XCTAssertLessThan(total, Self.budget, "stream render over budget")
    }
}

@MainActor
final class TranscriptBenchDebug {
    static func dump(_ host: NSView, name: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/" + name))
    }
}

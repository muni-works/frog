import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// A reply is drawn where it will rest from its first word (Cam, 2026-11-21): no card while it
/// streams, so finishing moves nothing. A reply (a wrapped paragraph, a list, another paragraph)
/// streams into a hosted transcript and is held open; its text view's frame and every line of its
/// text are measured in the transcript's document (so the view's own following can't hide a
/// shift), the turn finishes, and each must be where it was. The web's twin is
/// apps/web/test/streaming-position.test.ts.
///
/// Before: the answer streamed inside a card (`TypingBubble`'s padding and fill, the speed readout
/// beside it), so on finishing it moved up and left and its lines rewrapped wider.
@MainActor
final class StreamingPositionTests: XCTestCase {
    private var seq: UInt64 = 0
    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        // Now-ish, so the live stats in the picture read seconds, not months.
        let created = Int64(Date().timeIntervalSince1970 * 1000) - 30_000 + Int64(seq) * 20
        let line = #"{"seq":\#(seq),"session":"s","created":\#(created),"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func texts(_ v: NSView) -> [MessageTextView] { ((v as? MessageTextView).map { [$0] } ?? []) + v.subviews.flatMap(texts) }

    static let reply = [
        "The retry waited on `thread_rng()` for its jitter, so the third attempt could sleep longer than the mock store waits before it gives up, and the test failed about one run in nine.",
        "- The delay takes an `Rng`, so a test can seed it.",
        "- The jitter is half the base at most.",
        "All eleven upload tests pass now, every run.",
    ].joined(separator: "\n\n")

    override func setUp() async throws {
        InkReveal.off = true
        TranscriptMetrics.enabled = true
        TranscriptMetrics.shared.reset()
    }
    override func tearDown() async throws {
        InkReveal.off = false
        TranscriptMetrics.shared.reset()
        TranscriptMetrics.enabled = false
    }

    /// The top of the line under the reply (`kind`: its live stats, or its footer), from the
    /// bottom of the reply's last prose row, in the transcript's metrics.
    private func under(_ kind: TranscriptMetrics.Kind) -> Double? {
        let rows = TranscriptMetrics.shared.rows.values
        guard let line = rows.first(where: { $0.kind == kind }),
              let prose = rows.filter({ $0.kind == .prose }).map(\.box.maxY).max() else { return nil }
        return (Double(line.box.minY - prose) * 2).rounded() / 2
    }

    /// The reply's text view and its lines, in the transcript's document, to the half point.
    private func measure(_ host: NSView) throws -> [[Double]] {
        let views = texts(host).filter { $0.string.contains("every run") }
        let tv = try XCTUnwrap(views.first, "the reply's text view")
        let doc = try XCTUnwrap(tv.enclosingScrollView?.documentView, "the transcript's scroll view")
        func q(_ v: CGFloat) -> Double { (Double(v) * 2).rounded() / 2 }
        func row(_ r: NSRect) -> [Double] { let d = tv.convert(r, to: doc); return [q(d.minX), q(d.minY), q(d.width), q(d.height)] }
        var out = [row(tv.bounds)]
        let lm = try XCTUnwrap(tv.layoutManager)
        let origin = tv.textContainerOrigin
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tv.textContainer!)) { _, used, _, _, _ in
            out.append(row(used.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return out
    }

    private func shoot(_ host: NSView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["FROG_EDGES_OUT"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func testAFinishedReplyIsWhereItWasWhileItStreamed() throws {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "s")
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .frame(width: 1030, height: 700).background(Tokens.canvas))
        host.frame = CGRect(x: 0, y: 0, width: 1030, height: 700)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderInForTest()
        defer { w.close() }

        send(c, #""turn_started","turn":1,"input":"Why is upload_retries_on_503 flaky?""#)
        send(c, #""item_started","id":"m1","kind":{"type":"message"}"#)
        var rest = Substring(Self.reply)
        while !rest.isEmpty {
            let piece = rest.prefix(24)
            rest = rest.dropFirst(24)
            let json = String(data: try JSONEncoder().encode(String(piece)), encoding: .utf8)!
            send(c, #""item_delta","id":"m1","delta":{"type":"text","text":\#(json)}"#)
            pump(0.02)
        }
        pump(1)
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        let live = try measure(host)
        let stats = under(.stats)
        shoot(host, "stream-mac-live")

        let done = try JSONEncoder().encode(Self.reply)
        send(c, #""item_completed","id":"m1","item":{"type":"message","text":\#(String(data: done, encoding: .utf8)!)}"#)
        send(c, #""turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"context_tokens":900,"input_tokens":900,"output_tokens":120,"model_calls":1}"#)
        // Past any settling animation.
        pump(1)
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        let rest_ = try measure(host)
        let footer = under(.footer)
        shoot(host, "stream-mac-done")

        XCTAssertGreaterThan(live.count, 4, "measured the reply's lines")
        XCTAssertEqual(rest_.first, live.first, "the reply's text view didn't move or change size")
        XCTAssertEqual(rest_, live, "every line of the reply is where it was")
        // The stats under the writing answer become its footer in place.
        XCTAssertNotNil(stats, "measured the live stats")
        XCTAssertNotNil(footer, "measured the footer")
        XCTAssertEqual(footer, stats, "the footer sits where the stats were")
    }
}

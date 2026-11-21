import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// A turn that didn't finish still ends on its summary (Cam, 2026-11-21: "if a turn was
/// interrupted, it should still show the post-turn response summary footer"). A stopped turn's
/// footer says "Stopped" first, in its own muted words; a call stopped mid-stream counts what had
/// streamed (the engine's `usage.cut`) and reads "about"; a turn that used nothing draws no
/// footer, just "Stopped"; any other ending keeps its banner, with the footer under it. A
/// resumed session's history is the same events, so it draws the same. The web's twin is
/// apps/web/test/stopped-footer.test.ts.
@MainActor
final class StoppedFooterTests: XCTestCase {
    private var seq: UInt64 = 0

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

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let created = Int64(Date().timeIntervalSince1970 * 1000) - 60_000 + Int64(seq) * 1000
        let line = #"{"seq":\#(seq),"session":"s","created":\#(created),"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func usage(calls: Int, input: Int = 0, output: Int = 0, cut: (Int, Int)? = nil) -> String {
        let c = cut.map { #","cut":{"output_tokens":\#($0.0),"input_tokens":\#($0.1)}"# } ?? ""
        return #"{"context_tokens":900,"input_tokens":\#(input),"output_tokens":\#(output),"model_calls":\#(calls),"timing":{"wall_ms":12000,"prefill_ms":0,"decode_ms":0,"tool_ms":0},"model":"cloud/qwen3-coder-next"\#(c)}"#
    }

    /// The transcript after `events`, hosted off screen; the footers' words, top to bottom, and
    /// the end banners' words.
    private func render(_ events: [String], picture: String? = nil) -> (footers: [String], banners: [String]) {
        TranscriptMetrics.shared.reset()
        let scope = UUID().uuidString
        TranscriptMetrics.shared.scope = scope
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "s")
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .frame(width: 1030, height: 900).background(Tokens.canvas).environment(\.metricsScope, scope))
        host.frame = CGRect(x: 0, y: 0, width: 1030, height: 900)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderInForTest()
        defer { w.close() }
        for e in events { send(c, e) }
        pump(1)
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        if let dir = picture, let out = ProcessInfo.processInfo.environment["FROG_EDGES_OUT"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(dir).png"))
        }
        let footers = TranscriptMetrics.shared.rows.values.filter { $0.kind == .footer }.sorted { $0.box.minY < $1.box.minY }.map(\.text)
        let banners = TranscriptMetrics.shared.edges.values.filter { $0.kind == "error" && $0.part == "words" }.map(\.text)
        return (footers, banners)
    }

    private let writing = [
        #""item_started","id":"m1","kind":{"type":"message"}"#,
        #""item_delta","id":"m1","delta":{"type":"text","text":"The retry waits on the store, and"}"#,
    ]

    func testStoppedMidStreamSaysStoppedWithWhatHadStreamedAbout() {
        let r = render([#""turn_started","turn":1,"input":"why?""#] + writing
            + [#""turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 0, cut: (120, 900)))"#])
        XCTAssertEqual(r.footers.count, 1, "a footer: \(r)")
        let words = r.footers.first ?? ""
        XCTAssertTrue(words.hasPrefix("Stopped, Qwen3 Coder Next, 12s, about 120 tokens"), words)
        XCTAssertFalse(words.contains(" · "))
        XCTAssertEqual(r.banners, [], "the footer says it; no Stopped banner")
    }

    func testStoppedDuringAToolCallUsesTheProvidersFigures() {
        let r = render([#""turn_started","turn":1,"input":"run the tests""#,
                        #""item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#,
                        #""turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 1, input: 4000, output: 40))"#])
        let words = r.footers.first ?? ""
        XCTAssertTrue(words.hasPrefix("Stopped, Qwen3 Coder Next, 12s, 40 tokens"), words)
        XCTAssertFalse(words.contains("about"))
    }

    func testStoppedBeforeAnythingWasUsedHasNoFooter() {
        let r = render([#""turn_started","turn":1,"input":"hi""#,
                        #""turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 0))"#])
        XCTAssertEqual(r.footers, [])
        XCTAssertEqual(r.banners, ["Stopped"])
    }

    func testAnErrorKeepsItsBannerWithTheFooterUnderIt() {
        let r = render([#""turn_started","turn":1,"input":"go""#] + writing
            + [#""turn_ended","turn":1,"reason":{"type":"error","error":{"type":"connection","message":"connection reset by peer"}},"usage":\#(Self.usage(calls: 1, input: 2000, output: 300))"#])
        XCTAssertEqual(r.banners.count, 1, "the error banner: \(r)")
        XCTAssertTrue((r.footers.first ?? "").hasPrefix("Qwen3 Coder Next, 12s, 300 tokens"), "\(r.footers)")
    }

    /// For the PR (`FROG_EDGES_OUT` only): a reply stopped mid-stream, then a step stopped mid-run.
    func testPictureOfStoppedTurns() throws {
        guard ProcessInfo.processInfo.environment["FROG_EDGES_OUT"] != nil else { throw XCTSkip("FROG_EDGES_OUT not set") }
        _ = render([#""turn_started","turn":1,"input":"Why is upload_retries_on_503 flaky?""#,
                    #""item_started","id":"m1","kind":{"type":"message"}"#,
                    #""item_delta","id":"m1","delta":{"type":"text","text":"The retry waited on `thread_rng()` for its jitter, so the third attempt could sleep longer than the mock store waits before it gives up, and"}"#,
                    #""turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 0, cut: (48, 9000)))"#,
                    #""turn_started","turn":2,"input":"Just give me the one-line fix.""#,
                    #""item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test -q upload"}"#,
                    #""turn_ended","turn":2,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 1, input: 9400, output: 31))"#],
                   picture: "stopped-mac")
    }

    func testAResumedSessionsOldInterruptedTurnDrawsTheSame() {
        let r = render([#""turn_started","turn":1,"input":"why?""#] + writing + [
            #""turn_ended","turn":1,"reason":{"type":"cancelled"},"usage":\#(Self.usage(calls: 1, input: 900, output: 80))"#,
            #""turn_started","turn":2,"input":"go on""#,
            #""item_started","id":"m2","kind":{"type":"message"}"#,
            #""item_completed","id":"m2","item":{"type":"message","text":"Done."}"#,
            #""turn_ended","turn":2,"reason":{"type":"complete"},"usage":\#(Self.usage(calls: 1, input: 900, output: 3))"#,
        ])
        XCTAssertEqual(r.footers.count, 2, "both turns have a footer: \(r.footers)")
        XCTAssertTrue(r.footers.first?.hasPrefix("Stopped, ") == true, "\(r.footers)")
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Continuity: a context overflow that compaction couldn't fix renders as ONE line with a
/// rescue action (the raw payload is in the engine log, never the transcript; the rescue
/// button emits the `continue_session` op), and a successful compaction banners what it
/// kept at the transcript's top, one expander away.
final class ContinuityTests: XCTestCase {
    private func envelope(_ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"s","created":0,\#(body)}"#.utf8))
    }

    /// The event's own JSON (no envelope wrapper) — same decoder, same fields, what the
    /// log's `env` object holds.
    private func event(_ json: String) throws -> Event {
        try JSONDecoder.frog.decode(Event.self, from: Data(json.utf8))
    }

    /// The engine's new event decodes, with and without the raw detail (old logs replay).
    func testCompactionFailedDecodes() throws {
        let with = try envelope(
            #""event":"compaction_failed","detail":"HTTP 400: This model's maximum context length is 1048576 tokens. However, your request has 1579729 input tokens.""#)
        guard case .compactionFailed(let detail) = with.event else { return XCTFail() }
        XCTAssertTrue(detail.contains("1048576"))

        // Serde-defaulted: an old log's `compaction_failed` (or one from an engine that
        // bailed before filling `detail`) still decodes.
        let bare = try envelope(#""event":"compaction_failed""#)
        guard case .compactionFailed(let empty) = bare.event else { return XCTFail() }
        XCTAssertEqual(empty, "")
    }

    /// The rescue op encodes exactly as the engine's serde writes it.
    func testContinueSessionOpEncodes() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(
            Op.continueSession(from: "20261022-132854-96e9", why: "overflow")), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"from":"20261022-132854-96e9","op":"continue_session","why":"overflow"}"#)
    }

    /// The overflow event puts the conversation in the rescue state: one banner, no raw
    /// payload anywhere in the transcript.
    @MainActor
    func testOverflowSetsTheRescueState() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(#""event":"compaction_failed","detail":"raw 400 json dump""#))
        XCTAssertTrue(c.overflowRescue)

        let transcript = c.turns.flatMap { $0.items }.map(\.text).joined()
        XCTAssertFalse(transcript.contains("raw 400 json dump"), "the payload never renders")
        XCTAssertFalse(transcript.contains("compaction failed"), "the line comes from the banner, not a notice")
    }

    /// Pressing the rescue sends the op to the engine; the broker's answer (its callback)
    /// clears the banner and leaves one line.
    @MainActor
    func testTheRescueButtonEmitsTheOpAndTheAnswerLands() throws {
        let saved = Conversation.rescues
        defer { Conversation.rescues = saved }
        Conversation.rescues = { c, from in
            c.rescueAnswered(from: from, started: false)
        }
        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(#""event":"compaction_failed","detail":"raw""#))
        XCTAssertTrue(c.overflowRescue)

        c.startCarriedForward()
        guard case .continueSession(let from, _)? = link.sent.last else { return XCTFail("op wasn't sent") }
        XCTAssertEqual(from, "s")

        // The rescue callback answered (the stub broker installed above; item 3 wires a
        // real start): one honest line, banner gone.
        XCTAssertFalse(c.overflowRescue, "the banner goes once answered")
        let last = c.turns.last?.items.last
        guard case .notice(true)? = last?.kind else { return XCTFail("no answer line") }
        XCTAssertEqual(last?.text, "couldn't start a carried-forward session: \(from)")
    }

    /// Without a broker (this build can't host sessions), the button still answers honestly.
    @MainActor
    func testTheRescueWithoutAHostSaysSo() throws {
        let saved = Conversation.rescues
        Conversation.rescues = nil
        defer { Conversation.rescues = saved }

        let link = RecordingLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(#""event":"compaction_failed","detail":"raw""#))
        c.startCarriedForward()
        XCTAssertFalse(c.overflowRescue)
        guard case .continueSession? = link.sent.last else { return XCTFail("op wasn't sent") }
        let last = c.turns.last?.items.last
        guard case .notice(true)? = last?.kind, last?.text.contains("couldn't start") == true else {
            return XCTFail("no honest answer")
        }
    }

    // MARK: - Item 2: the carried-forward banner

    /// The engine's `compacted` event body, as the envelope wrapper takes it (fields only:
    /// the wrapper in `envelope()` opens and closes the outer object).
    private let receipt =
        #""event":"compacted","tokens_before":1016000,"tokens_after":24000,"summary":{"id":"20261022-122805-15f1","files":[{"path":"src/auth.rs","added":5,"removed":2},{"path":"tests/auth.rs","added":20,"removed":0}],"turns":[{"request":"fix the login bug","tools":["Read","Edit","Bash"],"tests":[{"command":"cargo test -p app","passed":true}],"outcome":"complete"},{"request":"now add a test","tools":["Write","Bash"],"tests":[{"command":"cargo test","passed":false}],"outcome":"stopped: tool call denied"}],"outcome":"stopped: tool call denied"}"#

    /// The extended `compacted` decodes with its receipt, and old logs (token counts alone)
    /// replay with `kept` nil — the banner just doesn't show.
    func testCompactedDecodesWithTheReceiptAndWithout() throws {
        let full = try event(
            #"{"event":"compacted","tokens_before":1016000,"tokens_after":24000,"summary":{"id":"20261022-122805-15f1","files":[{"path":"src/auth.rs","added":5,"removed":2},{"path":"tests/auth.rs","added":20,"removed":0}],"turns":[{"request":"fix the login bug","tools":["Read","Edit","Bash"],"tests":[{"command":"cargo test -p app","passed":true}],"outcome":"complete"},{"request":"now add a test","tools":["Write","Bash"],"tests":[{"command":"cargo test","passed":false}],"outcome":"stopped: tool call denied"}],"outcome":"stopped: tool call denied"}}"#)
        guard case .compacted(let before, let after, let kept) = full else { return XCTFail() }
        XCTAssertEqual(before, 1_016_000)
        XCTAssertEqual(after, 24_000)
        let k = try XCTUnwrap(kept)
        XCTAssertEqual(k.id, "20261022-122805-15f1")
        XCTAssertEqual(k.files.map(\.path), ["src/auth.rs", "tests/auth.rs"])
        XCTAssertEqual(k.files[0].added, 5)
        XCTAssertEqual(k.turns.count, 2)
        XCTAssertEqual(k.turns[0].request, "fix the login bug")
        XCTAssertEqual(k.turns[0].tests, [KeptTest(command: "cargo test -p app", passed: true)])
        XCTAssertEqual(k.turns[1].tests.first?.passed, false)
        XCTAssertEqual(k.outcome, "stopped: tool call denied")

        // An old log's `compacted`: no summary key at all.
        let old = try event(#"{"event":"compacted","tokens_before":900,"tokens_after":100}"#)
        guard case .compacted(_, _, let none) = old else { return XCTFail() }
        XCTAssertNil(none)
    }

    /// A successful compaction sets the banner state (durable: replayed sessions keep it).
    @MainActor
    func testCompactedSetsTheBannerState() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(receipt))
        XCTAssertEqual(c.carriedForward?.id, "20261022-122805-15f1")
        XCTAssertEqual(c.carriedForward?.files.count, 2)
        // The line under the turn stays as it was.
        XCTAssertTrue(c.turns.last?.items.last?.text.contains("Summarized the conversation") == true)
    }

    /// The banner renders with the expander; opening it shows the receipt (the #53 fields:
    /// files w/ +/−, turns with requests and outcomes, tests with pass/fail). Rendered to
    /// PNGs like SnapshotTests' fixtures: closed is one line, open is the receipt beneath.
    @MainActor
    func testBannerRendersWithExpanderAndReceipt() throws {
        let folded = try envelope(receipt)
        guard case .compacted(_, _, let kept) = folded.event, let kept else { return XCTFail() }
        let closed = try png(CarriedForwardBanner(kept: kept), width: 700)
        let opened = try png(CarriedForwardBanner(kept: kept, opened: true), width: 700)
        XCTAssertGreaterThan(closed.count, 0)
        XCTAssertGreaterThan(opened.count, 0)
        XCTAssertNotEqual(closed, opened, "the expander changed what's on screen")
        // Open shows the receipt (taller than the closed line) — the fields themselves are
        // asserted on the model in testCompactedDecodesWithTheReceiptAndWithout.
        let closedHeight = try height(CarriedForwardBanner(kept: kept), width: 700)
        let openHeight = try height(CarriedForwardBanner(kept: kept, opened: true), width: 700)
        XCTAssertGreaterThan(openHeight, closedHeight + 40, "the receipt is a real block, not a sliver")
    }

    /// A rendered view's PNG bytes, the SnapshotTests way (host, settle, bitmap).
    @MainActor
    private func png<V: View>(_ view: V, width: CGFloat, settle: TimeInterval = 0.2) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func height<V: View>(_ view: V, width: CGFloat) throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return host.fittingSize.height
    }
}

@MainActor
private final class RecordingLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    var sent: [Op] = []
    func send(_ op: Op) { sent.append(op) }
    func stop() {}
    var endDescription: String { "" }
    var isAlive: Bool { true }
}

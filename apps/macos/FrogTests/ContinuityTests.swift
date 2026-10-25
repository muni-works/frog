import XCTest
@testable import Frog

/// Item 1 of continuity: a context overflow that compaction couldn't fix renders as ONE
/// line with a rescue action — the raw provider payload never reaches the transcript (it's
/// in the engine log), and the rescue button emits the `continue_session` op.
final class ContinuityTests: XCTestCase {
    private func envelope(_ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"s","created":0,\#(body)}"#.utf8))
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

import XCTest
@testable import Frog

/// A window whose engine stream died mid-turn (a network error while compacting, say):
/// the engine recovered and finished, but the window never heard. It reconciles from the
/// session log — busy state settles to what the log's last turn says, never "Working…"
/// without a live engine behind it.
final class ReconcileTests: XCTestCase {
    /// `body` carries the event's own fields (the log flattens envelope and event into one
    /// object), so it's spliced in — no braces of its own.
    @MainActor
    private func envelope(_ seq: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }

    /// A conversation that saw the turn start but nothing since (the stream went quiet),
    /// whose engine is gone, and whose log ends in `turn_ended complete`.
    @MainActor
    func testReconcileClearsBusyWhenTheLogEndsInTurnEnded() async throws {
        let link = DeadLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"fix the sidebar""#))
        XCTAssertTrue(c.busy, "mid-turn")
        XCTAssertFalse(c.engineAlive, "the engine is gone, though the window still thinks it's working")

        // The fixture: the log says the turn finished (seq past what the window saw).
        let end = try envelope(2, #""event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#)
        let saved = Conversation.logReader
        defer { Conversation.logReader = saved }
        Conversation.logReader = { _, after in after >= 2 ? [] : [end] }

        await c.reconcile()

        XCTAssertFalse(c.busy, "the window settles with the log")
        if case .complete? = c.turns.last?.end {} else {
            XCTFail("the turn the log finished reads as complete")
        }
        XCTAssertFalse(c.engineAlive, "the engine is gone, so never Working…")
    }

    /// A quiet-but-alive engine mid-turn is a long think, not a death: nothing reconciles,
    /// and busy stands.
    @MainActor
    func testAliveEngineStaysBusy() async throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"x""#))
        XCTAssertTrue(c.busy)
        XCTAssertTrue(c.engineAlive)

        let saved = Conversation.logReader
        defer { Conversation.logReader = saved }
        Conversation.logReader = { _, _ in [] }

        await c.reconcile()

        XCTAssertTrue(c.busy, "nothing in the log to say otherwise")
        XCTAssertTrue(c.engineAlive)
    }

    /// The engine died with nothing new in the log (torn tail): the turn is over either way.
    @MainActor
    func testDeadEngineWithEmptyLogSettles() async throws {
        let link = DeadLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"x""#))
        XCTAssertTrue(c.busy)

        let saved = Conversation.logReader
        defer { Conversation.logReader = saved }
        Conversation.logReader = { _, _ in [] }

        await c.reconcile()

        XCTAssertFalse(c.busy, "no engine, no news: not Working… forever")
    }
}

@MainActor
private final class DeadLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    func send(_ op: Op) {}
    func stop() {}
    var endDescription: String { "" }
    var isAlive: Bool { false }
}

@MainActor
private final class LiveLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    func send(_ op: Op) {}
    func stop() {}
    var endDescription: String { "" }
    var isAlive: Bool { true }
}

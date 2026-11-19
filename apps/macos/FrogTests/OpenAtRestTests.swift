import XCTest
@testable import Frog

/// Opening a saved Frog Cloud conversation shows it at rest (Cam, 2026-11-19: "when loading a
/// long conversation, everything streams in individually - this is overwhelming, we should just
/// load the conversation and render the tail"). The gateway replays a session's history over the
/// socket in bursts; the real `CloudLink` (fed the gateway's frames, no socket) and a conversation
/// opened as `Workspace.openCloud` opens one (`Conversation.cloud`) must show nothing until the
/// history is all here, then all of it at once. Only what arrives after the open streams.
///
/// It failed before the fix: a cloud conversation opened with `replay: false`, so the history
/// went through the live event path one envelope at a time, and its turns grew burst by burst
/// (a local reopened session already held its history until `synced` and folded it in at once).
@MainActor
final class OpenAtRestTests: XCTestCase {
    private static let turns = 200
    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A long saved session's envelopes: per turn a message, a step and an answer. `open`: the
    /// last turn is still running.
    private static func history(open: Bool) -> [String] {
        var out: [String] = []
        var seq = 0
        let t0: Int64 = 1_790_000_000_000
        func push(_ event: String) { seq += 1; out.append(#"{"seq":\#(seq),"session":"s","created":\#(t0 + Int64(seq) * 100),"event":\#(event)}"#) }
        for n in 1...turns {
            push(#""turn_started","turn":\#(n),"input":"Question \#(n)""#)
            push(#""item_started","id":"t\#(n)","kind":{"type":"tool_call","name":"Bash","arg":"ls"}"#)
            push(#""item_completed","id":"t\#(n)","item":{"type":"tool_call","name":"Bash","arg":"ls","input":{},"outcome":"ok","output":"ok","display":null}"#)
            push(#""item_started","id":"m\#(n)","kind":{"type":"message"}"#)
            if open && n == turns { break }
            push(#""item_completed","id":"m\#(n)","item":{"type":"message","text":"Answer \#(n)."}"#)
            push(#""turn_ended","turn":\#(n),"reason":{"type":"complete"},"usage":{"context_tokens":1,"input_tokens":1,"output_tokens":1,"model_calls":1}"#)
        }
        return out
    }

    private func opened(lastSeq: Int) -> (CloudLink, Conversation) {
        let link = CloudLink(gateway: CloudGateway(token: "test"), session: "s", connect: false)
        let c = Conversation.cloud(folder: URL(fileURLWithPath: "/tmp/frog-open-at-rest"), link: link, session: "s")
        link.take(Data(#"{"welcome":{"protocol":1,"session":"s","engine":"test","last_seq":\#(lastSeq)}}"#.utf8))
        return (link, c)
    }

    /// The turn counts the conversation went through while the history arrived in bursts of 40,
    /// a run-loop turn apart (as the network delivers them).
    private func feed(_ link: CloudLink, _ c: Conversation, _ envelopes: [String]) -> [Int] {
        var counts: [Int] = []
        for start in stride(from: 0, to: envelopes.count, by: 40) {
            for e in envelopes[start..<min(start + 40, envelopes.count)] { link.take(Data(e.utf8)) }
            pump(0.01)
            if counts.last != c.turns.count { counts.append(c.turns.count) }
        }
        return counts
    }

    func testALongSavedConversationOpensWholeAtOnce() {
        let envelopes = Self.history(open: false)
        let (link, c) = opened(lastSeq: envelopes.count)
        let counts = feed(link, c, envelopes).filter { $0 > 0 }
        XCTAssertEqual(counts, [Self.turns], "the turns went in at once, not burst by burst (\(counts.count) steps)")
        XCTAssertFalse(c.busy, "a finished conversation is at rest")
    }

    func testAConversationOpenedMidReplyShowsItsHistoryAtOnceAndOnlyTheReplyStreams() {
        let envelopes = Self.history(open: true)
        let (link, c) = opened(lastSeq: envelopes.count)
        let counts = feed(link, c, envelopes).filter { $0 > 0 }
        XCTAssertEqual(counts, [Self.turns], "the history went in at once (\(counts.count) steps)")
        XCTAssertTrue(c.busy, "the turn still running shows working")
        // What arrives now is live: it streams.
        for w in 0..<5 {
            link.take(Data(#"{"seq":\#(envelopes.count + w + 1),"session":"s","created":1790000999000,"event":"item_delta","id":"m\#(Self.turns)","delta":{"type":"text","text":"word\#(w) "}}"#.utf8))
            pump(0.1)
        }
        let live = c.turns.last?.items.last
        XCTAssertTrue((live?.text ?? "").contains("word4"), "the live reply streams in")
    }

    /// The welcome's `last_seq` can count envelopes the replay doesn't send: a quiet socket ends
    /// the hold, rather than a conversation that never shows.
    func testAHistoryShorterThanTheWelcomeSaidStillShows() {
        let envelopes = Self.history(open: false)
        let (link, c) = opened(lastSeq: envelopes.count + 50)
        _ = feed(link, c, envelopes)
        XCTAssertEqual(c.turns.count, 0, "held while more may come")
        pump(0.6)
        XCTAssertEqual(c.turns.count, Self.turns, "shown once the replay went quiet")
    }
}

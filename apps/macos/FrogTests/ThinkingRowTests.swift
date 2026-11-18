import Foundation
import XCTest
@testable import Frog

/// The thinking row and the stats line (docs/design/transcript/spec.md, phase 2).
final class ThinkingRowTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Cases: Decodable {
        struct Stream: Decodable {
            struct Event: Decodable { let at: Int; let chunk: String; let thought: String? }
            let name: String
            let events: [Event]
            let shown: [Item.Thought]
        }
        let streams: [Stream]
    }

    /// The engine's thought line is shown verbatim: after every delta the row's line is the last
    /// `thought` a delta carried, and a finished think keeps the engine's `thoughts` list.
    /// The cases are the engine's own (docs/design/transcript/thoughts.json, from #420).
    func testTheRowShowsTheEnginesThoughtVerbatim() throws {
        let cases = try JSONDecoder.frog.decode(Cases.self, from: Data(contentsOf: root.appending(path: "docs/design/transcript/thoughts.json")))
        XCTAssertFalse(cases.streams.isEmpty)
        for c in cases.streams {
            var item = ItemState(id: "r", kind: .reasoning)
            var expected: String?
            for e in c.events {
                var json: [String: Any] = ["type": "reasoning", "text": e.chunk]
                if let t = e.thought { json["thought"] = t; expected = t }
                let delta = try JSONDecoder.frog.decode(Delta.self, from: JSONSerialization.data(withJSONObject: json))
                guard case .reasoning(let text, let thought) = delta else { return XCTFail("\(c.name): not reasoning") }
                item.text += text
                item.think(thought)
                XCTAssertEqual(item.thought, expected, "\(c.name) at \(e.at) ms")
            }
            let done: [String: Any] = ["type": "reasoning", "text": item.text,
                                       "thoughts": c.shown.map { ["text": $0.text, "start": $0.start, "end": $0.end, "ms": $0.ms] },
                                       "think_ms": 1840]
            guard case .reasoning(_, let meta) = try JSONDecoder.frog.decode(Item.self, from: JSONSerialization.data(withJSONObject: done)) else {
                return XCTFail("\(c.name): not reasoning")
            }
            XCTAssertEqual(meta.thoughts ?? [], c.shown, c.name)
            XCTAssertEqual(meta.thinkMs, 1840)
        }
    }

    func testDeltasJoinKeepingTheNewestThought() {
        XCTAssertEqual(Delta.reasoning("a", thought: "one").joined(.reasoning("b"))?.thoughtLine, "one")
        XCTAssertEqual(Delta.reasoning("a", thought: "one").joined(.reasoning("b", thought: "two"))?.thoughtLine, "two")
        XCTAssertNil(Delta.reasoning("a").joined(.reasoning("b"))?.thoughtLine)
    }

    func testOutputTokensDecode() throws {
        let env = try JSONDecoder.frog.decode(Envelope.self, from: Data(#"{"seq":1,"session":"s","created":0,"event":"output_tokens","turn":3,"output":120,"so_far":true}"#.utf8))
        guard case .outputTokens(let turn, let output, let soFar) = env.event else { return XCTFail("\(env.event)") }
        XCTAssertEqual([turn, output], [3, 120])
        XCTAssertTrue(soFar)
        let done = try JSONDecoder.frog.decode(Envelope.self, from: Data(#"{"seq":2,"session":"s","created":0,"event":"output_tokens","turn":3,"output":130}"#.utf8))
        guard case .outputTokens(_, _, let exact) = done.event else { return XCTFail() }
        XCTAssertFalse(exact)
    }

    // MARK: The row

    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func turn(_ items: [ItemState]) -> TurnState {
        var t = TurnState(number: 1, input: "go", images: [], more: [], startedAt: t0)
        t.items = items
        return t
    }

    private func thinking(_ thought: String?) -> ItemState {
        var r = ItemState(id: "r", kind: .reasoning, startedAt: t0)
        r.think(thought, at: t0)
        return r
    }

    func testThinkingShowsTheThoughtAfterItsFirstMoments() {
        let t = turn([thinking("Build one widget that walks through five stages")])
        let early = LiveState.of(t, waiting: nil, lastToken: t0.addingTimeInterval(0.3), now: t0.addingTimeInterval(0.4))!
        XCTAssertEqual([early.label, early.detail], ["Thinking", ""], "nothing for the first 600 ms")
        XCTAssertEqual(early.dot, .live)
        let mid = LiveState.of(t, waiting: nil, lastToken: t0.addingTimeInterval(8.5), now: t0.addingTimeInterval(9))!
        XCTAssertEqual(mid.detail, "Build one widget that walks through five stages")
        XCTAssertTrue(mid.thought)
        XCTAssertEqual(mid.reasoningID, "r")
        let still = LiveState.of(t, waiting: nil, lastToken: t0.addingTimeInterval(5), now: t0.addingTimeInterval(9))!
        XCTAssertEqual(still.dot, .still, "nothing arriving: held still")
    }

    func testStalledIsNamedAndThenOffersStop() {
        let t = turn([thinking("A line")])
        let quiet = LiveState.of(t, waiting: nil, lastToken: t0, now: t0.addingTimeInterval(12))!
        XCTAssertEqual(quiet.dot, .stalled)
        XCTAssertEqual(quiet.quiet, "No output for 12s")
        XCTAssertFalse(quiet.offersStop)
        let long = LiveState.of(t, waiting: nil, lastToken: t0, now: t0.addingTimeInterval(31))!
        XCTAssertEqual(long.quiet, "No output for 31s")
        XCTAssertTrue(long.offersStop)
    }

    func testOtherWorkCutsToItsVerbAndObject() {
        var read = ItemState(id: "a", kind: .tool(name: "Read", arg: "src/retry.rs"), startedAt: t0)
        let one = LiveState.of(turn([read]), waiting: nil, lastToken: nil, now: t0.addingTimeInterval(2))!
        XCTAssertEqual([one.label, one.detail], ["Reading", "src/retry.rs"])
        XCTAssertTrue(one.mono)
        XCTAssertFalse(one.thought)
        read.done = false
        let three = LiveState.of(turn([read, ItemState(id: "b", kind: .tool(name: "Read", arg: "b")), ItemState(id: "c", kind: .tool(name: "Read", arg: "c"))]),
                                 waiting: nil, lastToken: nil, now: t0)!
        XCTAssertEqual([three.label, three.detail], ["Reading", "3 files"], "parallel steps fold into a count")
        let you = LiveState.of(turn([read]), waiting: "Allow cargo test -q upload?", lastToken: nil, now: t0)!
        XCTAssertEqual([you.label, you.detail], ["Waiting for you", ""], "the card above says what")
        XCTAssertEqual(you.dot, .you, "amber only when it's waiting on a person")
    }

    func testNoRowWhileTheAnswerWrites() {
        var answer = ItemState(id: "m", kind: .message, text: "A transformer reads", startedAt: t0)
        answer.done = false
        XCTAssertNil(LiveState.of(turn([answer]), waiting: nil, lastToken: t0, now: t0.addingTimeInterval(3)))
    }

    // MARK: The stats

    func testStats() {
        XCTAssertEqual(LiveStats(elapsed: 0.6, tokens: nil, soFar: false, perSecond: nil, slow: false).text, "", "time after the first second")
        XCTAssertEqual(LiveStats(elapsed: 19.7, tokens: 1105, soFar: true, perSecond: 58.2, slow: false).text, "19s · 1,105 tokens · 58 tok/s")
        XCTAssertEqual(LiveStats(elapsed: 27, tokens: 1610, soFar: true, perSecond: 12, slow: true).text, "27s · 1,610 tokens · 12 tok/s, slower than usual")
        XCTAssertEqual(LiveStats(elapsed: 125, tokens: nil, soFar: false, perSecond: nil, slow: false).text, "2m 5s")
        XCTAssertEqual(LiveStats(elapsed: 7 * 86_400, tokens: nil, soFar: false, perSecond: nil, slow: false).text, "",
                       "a reopened session's week-old clock isn't shown")
        XCTAssertEqual(LiveStats(elapsed: 39, tokens: 1212, soFar: false, perSecond: 40, slow: false, waited: 6.4).text, "39s · waited 6s",
                       "waiting on you: the clock and how long (board 8, C)")
        XCTAssertTrue(LiveStats(elapsed: 9, tokens: 388, soFar: true, perSecond: 58, slow: false).help.contains("388 tokens so far"))
        XCTAssertFalse(LiveStats(elapsed: 9, tokens: 388, soFar: false, perSecond: 58, slow: false).help.contains("so far"))
    }

    func testStatsFromThePulse() {
        let pulse = LivePulse()
        pulse.start(turn: 1)
        pulse.tick(at: t0.addingTimeInterval(1))
        pulse.tokens(turn: 1, output: 400, soFar: true)
        let t = turn([thinking("x")])
        let s = LiveStats.of(t, pulse: pulse, usual: 60, now: t0.addingTimeInterval(9))
        XCTAssertEqual(s.text, "9s · 400 tokens · 50 tok/s")
        XCTAssertFalse(s.slow)
        let slow = LiveStats.of(t, pulse: pulse, usual: 400, now: t0.addingTimeInterval(9))
        XCTAssertTrue(slow.slow, "under a quarter of the usual rate after 5 s")
    }

    // MARK: Settled and opened

    @MainActor
    func testTheSettledLineUsesTheEnginesThinkTime() {
        var r = ItemState(id: "r", kind: .reasoning, startedAt: t0, endedAt: t0.addingTimeInterval(56))
        r.done = true
        XCTAssertEqual(ThoughtLineView.words(r), "Thought for 56s", "an old log: the item's own times")
        r.thinkMs = 31_000
        XCTAssertEqual(ThoughtLineView.words(r), "Thought for 31s")
        var stopped = ItemState(id: "s", kind: .reasoning, startedAt: t0, endedAt: t0.addingTimeInterval(12))
        stopped.done = false
        XCTAssertEqual(ThoughtLineView.words(stopped), "Stopped after 12s")
    }

    @MainActor
    func testTheOutlineOpensEachLinesParagraph() {
        var r = ItemState(id: "r", kind: .reasoning, text: "The user wants a visual — explanation.\n\nBuild one widget.\n\n")
        r.done = true
        // UTF-16 offsets: the dash is one code unit, so the second paragraph starts at 40.
        r.thoughts = [Item.Thought(text: "The user wants a visual", start: 0, end: 38, ms: 0),
                      Item.Thought(text: "Build one widget", start: 40, end: 57, ms: 1200)]
        let lines = ThinkingOutline.lines(r)
        XCTAssertEqual(lines.map(\.text), ["The user wants a visual", "Build one widget"])
        XCTAssertEqual(lines[0].paragraph, "The user wants a visual — explanation.")
        XCTAssertEqual(lines[1].paragraph, "Build one widget.")
        // Live: the lines shown so far, matched to their paragraphs.
        var live = ItemState(id: "l", kind: .reasoning, text: "Let me look.\n\nBuild one widget that walks through five stages.\n\nMore")
        live.think("Build one widget that walks through five stages")
        XCTAssertEqual(ThinkingOutline.lines(live).first?.paragraph, "Build one widget that walks through five stages.")
    }
}

private extension Delta {
    var thoughtLine: String? { if case .reasoning(_, let t) = self { t } else { nil } }
}

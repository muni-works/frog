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
        guard case .outputTokens(let turn, let output, let soFar, let slow, let cached) = env.event else { return XCTFail("\(env.event)") }
        XCTAssertEqual([turn, output], [3, 120])
        XCTAssertTrue(soFar)
        XCTAssertFalse(slow, "absent means not slow")
        XCTAssertNil(cached)
        let done = try JSONDecoder.frog.decode(Envelope.self, from: Data(#"{"seq":2,"session":"s","created":0,"event":"output_tokens","turn":3,"output":131,"cached":9000}"#.utf8))
        guard case .outputTokens(_, _, let exact, _, let fromCache) = done.event else { return XCTFail() }
        XCTAssertFalse(exact)
        XCTAssertEqual(fromCache, 9000)
        let slowly = try JSONDecoder.frog.decode(Envelope.self, from: Data(#"{"seq":3,"session":"s","created":0,"event":"output_tokens","turn":3,"output":125,"so_far":true,"slow":true}"#.utf8))
        guard case .outputTokens(_, _, _, let isSlow, _) = slowly.event else { return XCTFail() }
        XCTAssertTrue(isSlow)
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
        let early = LiveState.of(t, waiting: false, lastToken: t0.addingTimeInterval(0.3), now: t0.addingTimeInterval(0.4))!
        XCTAssertEqual([early.label, early.detail], ["Thinking", ""], "nothing for the first 600 ms")
        XCTAssertEqual(early.dot, .live)
        let mid = LiveState.of(t, waiting: false, lastToken: t0.addingTimeInterval(8.5), now: t0.addingTimeInterval(9))!
        XCTAssertEqual(mid.detail, "Build one widget that walks through five stages")
        XCTAssertTrue(mid.thought)
        XCTAssertEqual(mid.reasoningID, "r")
        let still = LiveState.of(t, waiting: false, lastToken: t0.addingTimeInterval(5), now: t0.addingTimeInterval(9))!
        XCTAssertEqual(still.dot, .still, "nothing arriving: held still")
    }

    func testStalledIsNamedAndThenOffersStop() {
        let t = turn([thinking("A line")])
        let quiet = LiveState.of(t, waiting: false, lastToken: t0, now: t0.addingTimeInterval(12))!
        XCTAssertEqual(quiet.dot, .stalled)
        XCTAssertEqual(quiet.text, "No output for 12s", "the label says how long; the thought steps aside")
        // At 30 s the engine asks (a question); the row offers nothing of its own.
        XCTAssertEqual(LiveState.of(t, waiting: false, lastToken: t0, now: t0.addingTimeInterval(31))!.text, "No output for 31s")
    }

    func testOtherWorkCutsToItsVerbAndObject() {
        var read = ItemState(id: "a", kind: .tool(name: "Read", arg: "src/retry.rs"), startedAt: t0)
        let one = LiveState.of(turn([read]), waiting: false, lastToken: nil, now: t0.addingTimeInterval(2))!
        XCTAssertEqual([one.label, one.detail], ["Reading", "src/retry.rs"])
        XCTAssertTrue(one.mono)
        XCTAssertFalse(one.thought)
        read.done = false
        let three = LiveState.of(turn([read, ItemState(id: "b", kind: .tool(name: "Read", arg: "b")), ItemState(id: "c", kind: .tool(name: "Read", arg: "c"))]),
                                 waiting: false, lastToken: nil, now: t0)!
        XCTAssertEqual(three.text, "Reading 3 files", "parallel steps fold into a count")
        let mixed = LiveState.of(turn([read, ItemState(id: "g", kind: .tool(name: "Grep", arg: "x"))]), waiting: false, lastToken: nil, now: t0)!
        XCTAssertEqual(mixed.text, "Running 2 steps", "different steps: verbs.json's mixed words")
        let you = LiveState.of(turn([read]), waiting: true, lastToken: nil, now: t0)!
        XCTAssertEqual([you.label, you.detail], ["Waiting for you", ""], "the card above says what")
        XCTAssertEqual(you.dot, .you, "amber only when it's waiting on a person")
    }

    func testNoRowWhileTheAnswerWrites() {
        var answer = ItemState(id: "m", kind: .message, text: "A transformer reads", startedAt: t0)
        answer.done = false
        XCTAssertNil(LiveState.of(turn([answer]), waiting: false, lastToken: t0, now: t0.addingTimeInterval(3)))
    }

    // MARK: The stats

    func testStats() {
        XCTAssertEqual(LiveStats(elapsed: 0.4, tokens: nil, soFar: false, perSecond: nil, slow: false).text, "", "time after the first second")
        XCTAssertEqual(LiveStats(elapsed: 19.4, tokens: 1105, soFar: true, perSecond: 58, slow: false).text, "19s · 1,105 tokens · 58 tok/s")
        XCTAssertEqual(LiveStats(elapsed: 27, tokens: 1610, soFar: true, perSecond: 12, slow: true).text, "27s · 1,610 tokens · 12 tok/s · Slow",
                       "the engine's slow, not the Mac's own")
        XCTAssertEqual(LiveStats(elapsed: 125, tokens: nil, soFar: false, perSecond: nil, slow: false).text, "2m 5s")
        XCTAssertEqual(LiveStats(elapsed: 39, tokens: 1212, soFar: false, perSecond: 40, slow: false, waited: 6.4).text, "39s · waited 6s",
                       "waiting on you: the clock and how long (board 8, C)")
        XCTAssertEqual(LiveStats(elapsed: 7 * 86_400, tokens: nil, soFar: false, perSecond: nil, slow: false, waited: 7 * 86_400).text,
                       "7d 0h · waited 7d 0h", "the clock shows at any length, in days and hours past a day, as on the web")
        XCTAssertEqual(LiveStats(elapsed: 40, tokens: 900, soFar: true, perSecond: nil, slow: false, quiet: 12).text, "40s · 900 tokens · no output for 12s",
                       "an answer writing with nothing arriving")
        let s = LiveStats(elapsed: 9, tokens: 388, soFar: true, perSecond: 58, slow: false, cached: 11_900, firstToken: 0.8, thinking: true)
        XCTAssertTrue(s.help.contains("Thinking for 9 seconds"))
        XCTAssertTrue(s.help.contains("388 tokens so far at 58 tokens per second"))
        XCTAssertTrue(s.help.contains("Read 11,900 tokens from cache"))
        XCTAssertTrue(s.help.contains("First token after 0.8 seconds"))
    }

    /// The dump writes the stats' ticking figures as the web's metrics.mjs does.
    @MainActor
    func testTheDumpWritesTickingFiguresAsHashes() {
        XCTAssertEqual(TranscriptMetrics.ticking("10080m 0s · waited 10080m 0s"), "#s · waited #s")
        XCTAssertEqual(TranscriptMetrics.ticking("19s · 1,105 tokens · 58 tok/s · Slow"), "#s · # tokens · # tok/s · Slow")
    }

    func testStatsFromThePulse() {
        let pulse = LivePulse()
        pulse.start(turn: 1)
        pulse.tick(at: t0.addingTimeInterval(1))
        pulse.tokens(turn: 1, output: 400, soFar: true, slow: true, cached: 9000)
        let s = LiveStats.of(turn([thinking("x")]), pulse: pulse, now: t0.addingTimeInterval(9))
        XCTAssertEqual(s.tokens, 400)
        XCTAssertTrue(s.slow)
        XCTAssertEqual(s.cached, 9000)
        XCTAssertEqual(s.firstToken ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(s.perSecond, "no speed until two seconds of counts")
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

extension ThinkingRowTests {
    /// The engine's quiet call is an ordinary question anchored on the streaming think: it draws
    /// under that think (as on the web); one with no item, or an Ask call's, waits after the turn.
    @MainActor
    func testAQuestionOnAThinkDrawsUnderIt() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        try [
            #"{"seq":1,"session":"s","created":0,"event":"turn_started","turn":1,"input":"go"}"#,
            #"{"seq":2,"session":"s","created":0,"event":"item_started","id":"r1","kind":{"type":"reasoning"}}"#,
            #"{"seq":3,"session":"s","created":0,"event":"item_started","id":"a1","kind":{"type":"tool_call","name":"Ask","arg":""}}"#,
        ].map { try JSONDecoder.frog.decode(Envelope.self, from: Data($0.utf8)) }.forEach(c.ingest)
        func q(_ item: String) throws -> Question {
            try JSONDecoder.frog.decode(Question.self, from: Data(#"{"id":"q","item":"\#(item)","question":"No output for 30s","options":[{"label":"Keep waiting"},{"label":"Stop the turn"}]}"#.utf8))
        }
        XCTAssertTrue(c.drawsQuestionInline(try q("r1")), "anchored on the think")
        XCTAssertFalse(c.drawsQuestionInline(try q("")), "no item: after the turn")
        XCTAssertFalse(c.drawsQuestionInline(try q("a1")), "an Ask call's question stays where it was")
        let row = TurnPart.segment(.activity(ActivityGroup(steps: c.turns[0].items)))
        XCTAssertTrue(row.holds("r1"))
        XCTAssertFalse(row.holds(""))
    }
}

private extension Delta {
    var thoughtLine: String? { if case .reasoning(_, let t) = self { t } else { nil } }
}

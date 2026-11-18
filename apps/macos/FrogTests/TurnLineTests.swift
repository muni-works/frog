import Foundation
import XCTest
@testable import Frog

/// The turn line and the turn panel (docs/design/transcript/spec.md, phase 3).
final class TurnLineTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Cases: Decodable {
        struct Case: Decodable {
            let name: String
            let events: [JSONValue]
            let segments: [TurnTimeline.Segment]
        }
        let cases: [Case]
    }

    /// The Mac works out the same segments as the engine's reference (timeline.rs) for every
    /// case in docs/design/transcript/timeline.json.
    func testSegmentsMatchTheEnginesCases() throws {
        let data = try Data(contentsOf: root.appending(path: "docs/design/transcript/timeline.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = raw["cases"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for c in cases {
            let name = c["name"] as! String
            var timeline = TurnTimeline()
            for e in c["events"] as! [Any] {
                let env = try JSONDecoder.frog.decode(Envelope.self, from: JSONSerialization.data(withJSONObject: e))
                timeline.record(env)
            }
            let want = try JSONDecoder.frog.decode([TurnTimeline.Segment].self,
                                                   from: JSONSerialization.data(withJSONObject: c["segments"] as Any))
            XCTAssertEqual(timeline.segments(), want, name)
        }
    }

    private func seg(_ k: TurnTimeline.Kind, _ a: UInt64, _ b: UInt64, _ item: String?) -> TurnTimeline.Segment {
        TurnTimeline.Segment(kind: k, startMs: a, endMs: b, item: item)
    }

    /// The line is 200 by 16: the strip along the bottom scaled to the turn, the pace above it,
    /// and nothing but the strip under 420 wide.
    func testTheLinesShape() {
        let pace = TurnUsage.Pace(bucketMs: 1000, tokens: [58, 0, 30])
        let shape = TurnLineShape.of(segments: [seg(.thinking, 0, 1000, "r"), seg(.tool, 1000, 4000, "t")], lengthMs: 4000, pace: pace)
        XCTAssertEqual(shape.pieces.map(\.x), [0, 50])
        XCTAssertEqual(shape.pieces.map(\.width), [50, 150])
        XCTAssertEqual(shape.curve.count, 3)
        XCTAssertEqual(shape.curve[0].y, TurnLineShape.height - TurnLineShape.strip - 1 - (TurnLineShape.height - TurnLineShape.strip - 2), accuracy: 0.01,
                       "the fastest bucket reaches the top")
        XCTAssertEqual(shape.curve[1].y, TurnLineShape.height - TurnLineShape.strip - 1, accuracy: 0.01, "on the floor while a tool runs")
        XCTAssertTrue(TurnLineShape.of(segments: [], lengthMs: 4000, pace: pace, curve: false).curve.isEmpty, "narrow: the strip alone")
        XCTAssertTrue(TurnLineShape.of(segments: [], lengthMs: 4000, pace: nil).curve.isEmpty, "an old turn: no pace, no curve")
        XCTAssertEqual(TurnLineShape.rate(at: 2500, pace: pace), 30)
        XCTAssertEqual(TurnLineShape.rate(at: 9000, pace: pace), 0)
    }

    /// The step under the pointer is the narrowest segment there: a short write over a long tool.
    func testThePointersStep() {
        let shape = TurnLineShape.of(segments: [seg(.tool, 0, 4000, "t"), seg(.writing, 1000, 1400, "m")], lengthMs: 4000, pace: nil)
        XCTAssertEqual(shape.piece(at: 55)?.item, "m")
        XCTAssertEqual(shape.piece(at: 150)?.item, "t")
    }

    @MainActor
    func testTheReadoutsWords() {
        var t = TurnState(number: 1, input: "go", images: [], more: [], startedAt: .now)
        var run = ItemState(id: "t5", kind: .tool(name: "Bash", arg: "cargo test -q upload"))
        run.done = true
        run.result = Item.ToolResult(name: "Bash", arg: "cargo test -q upload", input: nil, outcome: .error, output: "", display: nil)
        t.items = [run, ItemState(id: "r", kind: .reasoning), ItemState(id: "m", kind: .message)]
        func words(_ k: TurnTimeline.Kind, _ item: String?) -> String {
            TurnLine.step(TurnLineShape.Piece(kind: k, x: 0, width: 0, item: item, startMs: 15_400, endMs: 24_400), in: t)
        }
        XCTAssertEqual(words(.tool, "t5"), "Failed cargo test -q upload",
                       "the step as its line says it (Failed is a failed step's verb), not its result")
        XCTAssertEqual(words(.thinking, "r"), "Thought")
        XCTAssertEqual(words(.writing, "m"), "Wrote the answer")
        XCTAssertEqual(words(.waiting, "t5"), "Waited for you")
    }

    /// Where the time went: each kind's union, so tools that ran together count once.
    func testWhereTheTimeWent() {
        let parts = TurnPanel.breakdown([seg(.thinking, 0, 15_000, "r"), seg(.tool, 15_000, 20_000, "a"), seg(.tool, 16_000, 24_000, "b"),
                                         seg(.waiting, 29_000, 33_000, "c"), seg(.writing, 47_000, 56_000, "m")])
        XCTAssertEqual(parts.map(\.kind), [.thinking, .tool, .waiting, .writing])
        XCTAssertEqual(parts.map(\.ms), [15_000, 9_000, 4_000, 9_000])
    }

    /// A tool cut by a wait keeps one waterfall row; ticks give four to eight marks.
    @MainActor
    func testWaterfallRows() {
        let t = TurnState(number: 1, input: "go", images: [], more: [], startedAt: .now)
        let rows = TurnWaterfall.rows([seg(.tool, 0, 2000, "t"), seg(.waiting, 2000, 6000, "t"), seg(.tool, 6000, 9000, "t")], turn: t)
        XCTAssertEqual(rows.map(\.kind), [.tool, .waiting])
        XCTAssertEqual([rows[0].startMs, rows[0].endMs], [0, 9000])
        XCTAssertEqual(TurnWaterfall.tickStep(56_000), 15_000)
        XCTAssertEqual(TurnWaterfall.tickStep(6_000), 1_000)
    }
}

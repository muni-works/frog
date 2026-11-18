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
}

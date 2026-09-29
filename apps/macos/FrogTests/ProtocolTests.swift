import XCTest
@testable import Frog

/// Lines captured from a real `frog -p --json` run, so the Swift mirror can't drift from the engine.
final class ProtocolTests: XCTestCase {
    private func decode(_ line: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
    }

    func testFixturesAllDecode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "events", withExtension: "jsonl"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let env = try decode(String(line))
            if case .unknown(let name) = env.event {
                XCTFail("unknown event \(name)")
            }
        }
    }

    func testStatusIsFlattenedIntoTheEnvelope() throws {
        let env = try decode(#"{"seq":1,"session":"s","created":0,"event":"status","model":"ollama/x","mode":"accept-edits","cwd":"/tmp","messages":2,"context_tokens":null,"context_window":32768,"tool_mode":"json","tier":"weak","tokens_per_sec":null,"todos":[]}"#)
        guard case .status(let s) = env.event else { return XCTFail() }
        XCTAssertEqual(s.mode, .acceptEdits)
        XCTAssertEqual(s.contextWindow, 32768)
        XCTAssertNil(s.contextTokens)
    }

    func testToolCallWithDiff() throws {
        let env = try decode(#"{"seq":9,"session":"s","created":0,"event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Edit","arg":"a.rs","input":{"file_path":"a.rs"},"outcome":"ok","output":"Edited a.rs","display":"...","diff":{"path":"a.rs","created":false,"added":1,"removed":1,"hunks":[{"lines":[{"kind":"remove","old":2,"new":null,"text":"a - b"},{"kind":"add","old":null,"new":2,"text":"a + b"}]}]}}}"#)
        guard case .itemCompleted(_, .toolCall(let r)) = env.event else { return XCTFail() }
        XCTAssertEqual(r.diff?.added, 1)
        XCTAssertEqual(r.diff?.hunks.first?.lines.first?.kind, .remove)
    }

    func testEndReasonsAndSynced() throws {
        let ended = try decode(#"{"seq":5,"session":"s","created":0,"event":"turn_ended","turn":1,"reason":{"type":"error","error":{"type":"provider","status":404,"message":"model not found"}},"usage":{"context_tokens":null,"input_tokens":0,"output_tokens":0,"model_calls":0,"tokens_per_sec":null}}"#)
        guard case .turnEnded(_, .error(let e), _) = ended.event else { return XCTFail() }
        XCTAssertEqual(e.status, 404)

        let synced = try decode(#"{"seq":7,"session":"s","created":0,"event":"synced","upto":6}"#)
        guard case .synced(let upto) = synced.event else { return XCTFail() }
        XCTAssertEqual(upto, 6)
    }

    func testTurnEnergy() throws {
        let local = try decode(#"{"seq":5,"session":"s","created":0,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":10,"output_tokens":5,"model_calls":1,"energy":{"local_wh":0.42}}}"#)
        guard case .turnEnded(_, _, let u) = local.event, let e = u.energy else { return XCTFail() }
        XCTAssertFalse(e.estimated)
        XCTAssertEqual(ModelStats.energy(e.totalWh), "0.4 Wh")

        let hosted = try decode(#"{"seq":5,"session":"s","created":0,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":10,"output_tokens":5,"model_calls":1,"energy":{"local_wh":0.02,"remote_wh":0.05}}}"#)
        guard case .turnEnded(_, _, let h) = hosted.event, let he = h.energy else { return XCTFail() }
        XCTAssertEqual(ModelStats.energy(he.totalWh, estimated: he.estimated), "~0.07 Wh")
        XCTAssertEqual(ModelStats.energy(0.004), "<0.01 Wh")
        XCTAssertEqual(ModelStats.energy(12.4), "12 Wh")
    }

    func testOpsEncodeLikeTheEngineExpects() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = { (op: Op) in String(decoding: try enc.encode(op), as: UTF8.self) }
        XCTAssertEqual(try json(.submit("hi")), #"{"op":"submit","text":"hi"}"#)
        XCTAssertEqual(try json(.permission(id: "p", decision: .allowAlways)), #"{"decision":"allow_always","id":"p","op":"permission"}"#)
        XCTAssertEqual(try json(.setMode(.acceptEdits)), #"{"mode":"accept-edits","op":"set_mode"}"#)
        XCTAssertEqual(try json(.subscribe(after: 0)), #"{"after":0,"op":"subscribe"}"#)
    }
}

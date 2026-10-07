import XCTest
@testable import Frog

/// Lines captured from a real `frog -p --json` run, so the Swift mirror can't drift from the engine.
final class ProtocolTests: XCTestCase {
    private func decode(_ line: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
    }

    func testImagePreviewDeltaDecodesWithoutText() throws {
        let env = try decode(#"{"seq":1,"session":"s","created":0,"event":"item_delta","id":"image","delta":{"type":"image_preview","image":{"mime":"image/png","data":"png"},"step":3,"of":8,"image_index":0}}"#)
        guard case .itemDelta("image", .imagePreview(let image, let step, let of, let index)) = env.event else { return XCTFail() }
        XCTAssertEqual(image.mime, "image/png")
        XCTAssertEqual(step, 3); XCTAssertEqual(of, 8); XCTAssertEqual(index, 0)
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

    // The engine's own serialization, from `protocol::tests` and `present::tests`.
    func testAskAndPresent() throws {
        let asked = try decode(#"{"seq":4,"session":"s","created":0,"event":"question","id":"q1","item":"t1","question":"Which?","options":[{"label":"A"},{"label":"B","detail":"slower"}],"allow_other":true}"#)
        guard case .question(let q) = asked.event else { return XCTFail() }
        XCTAssertEqual(q.options.map(\.label), ["A", "B"])
        XCTAssertEqual(q.options[1].detail, "slower")
        XCTAssertEqual(q.allowOther, true)
        XCTAssertNil(q.multi)
        let resolved = try decode(#"{"seq":5,"session":"s","created":0,"event":"question_resolved","id":"q1","other":"neither"}"#)
        guard case .questionResolved("q1") = resolved.event else { return XCTFail() }

        let shown = try decode(#"{"seq":9,"session":"s","created":0,"event":"item_completed","id":"t2","item":{"type":"tool_call","name":"Present","arg":"","input":{},"outcome":"ok","output":"Shown","present":{"title":"Tests","blocks":[{"type":"table","columns":["test","ms"],"rows":[["resume","12"]]},{"type":"callout","tone":"warning","text":"careful"},{"type":"steps","items":["a","b"],"current":1},{"type":"sparkline"}]}}}"#)
        guard case .itemCompleted(_, .toolCall(let r)) = shown.event, let p = r.present else { return XCTFail() }
        XCTAssertEqual(p.title, "Tests")
        XCTAssertEqual(p.blocks, [
            .table(columns: ["test", "ms"], rows: [["resume", "12"]]),
            .callout(tone: .warning, text: "careful"),
            .steps(items: ["a", "b"], current: 1),
            .unknown,
        ])

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = { (op: Op) in String(decoding: try enc.encode(op), as: UTF8.self) }
        XCTAssertEqual(try json(.answer(id: "q1", choices: ["A"], other: nil)), #"{"choices":["A"],"id":"q1","op":"answer"}"#)
        XCTAssertEqual(try json(.answer(id: "q1", choices: [], other: nil)), #"{"id":"q1","op":"answer"}"#)
        XCTAssertEqual(try json(.setClientCaps(panes: true, ask: true)), #"{"ask":true,"op":"set_client_caps","panes":true}"#)
    }

    func testPaneOpsEncode() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = { (op: Op) in String(decoding: try enc.encode(op), as: UTF8.self) }
        XCTAssertEqual(try json(.setClientCaps(panes: true)), #"{"op":"set_client_caps","panes":true}"#)
        XCTAssertEqual(try json(.warm(draft: nil)), #"{"op":"warm"}"#)
        XCTAssertEqual(try json(.warm(draft: "fix")), #"{"draft":"fix","op":"warm"}"#)
        XCTAssertEqual(try json(.paneOpen(kind: .terminal, cwd: "/p", cols: 80, rows: 24)), #"{"cols":80,"cwd":"/p","kind":"terminal","op":"pane_open","rows":24}"#)
        XCTAssertEqual(try json(.paneOpen(kind: .preview, url: "http://localhost:3000")), #"{"kind":"preview","op":"pane_open","url":"http://localhost:3000"}"#)
        XCTAssertEqual(try json(.paneInput(id: "t1", data: "ls\r")), #"{"data":"ls\r","id":"t1","op":"pane_input"}"#)
        XCTAssertEqual(try json(.paneResize(id: "t1", cols: 100, rows: 30)), #"{"cols":100,"id":"t1","op":"pane_resize","rows":30}"#)
        XCTAssertEqual(try json(.paneClose(id: "t1")), #"{"id":"t1","op":"pane_close"}"#)
        XCTAssertEqual(
            try json(.paneReport(PaneReport(id: "p1", kind: .network, level: "error", message: "GET /api → 500", url: "http://localhost:3000/api", status: 500))),
            #"{"id":"p1","kind":"network","level":"error","message":"GET /api → 500","op":"pane_report","status":500,"url":"http://localhost:3000/api"}"#)
        XCTAssertEqual(try json(.paneReply(call: "c1", result: .object(["ok": .bool(true)]))), #"{"call":"c1","op":"pane_reply","result":{"ok":true}}"#)
        XCTAssertEqual(try json(.paneReply(call: "c2", result: nil, error: "no")), #"{"call":"c2","error":"no","op":"pane_reply","result":null}"#)
        XCTAssertEqual(try json(.paneMention(id: "p1", mention: "@button.submit", context: "tag: button")), #"{"context":"tag: button","id":"p1","mention":"@button.submit","op":"pane_mention"}"#)
    }

    func testPaneEventsDecode() throws {
        let opened = try decode(#"{"seq":1,"session":"s","created":0,"event":"pane_opened","id":"t1","kind":"terminal","title":"zsh","cwd":"/p"}"#)
        guard case .paneOpened(let id, let kind, let title, let cwd, _) = opened.event else { return XCTFail() }
        XCTAssertEqual([id, kind.rawValue, title, cwd ?? ""], ["t1", "terminal", "zsh", "/p"])

        let screen = try decode(#"{"seq":2,"session":"s","created":0,"event":"pane_screen","id":"t1","cols":80,"rows":2,"lines":["$ ls","a b"],"cursor":[1,3],"seq":7}"#)
        guard case .paneScreen(let g) = screen.event else { return XCTFail() }
        XCTAssertEqual(g.lines, ["$ ls", "a b"])
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 3)

        let req = try decode(##"{"seq":3,"session":"s","created":0,"event":"pane_request","call":"c1","id":"p1","action":"click","args":{"selector":"#go"}}"##)
        guard case .paneRequest(let r) = req.event else { return XCTFail() }
        XCTAssertEqual(r.action, "click")
        XCTAssertEqual(r.args["selector"]?.string, "#go")

        let closed = try decode(#"{"seq":4,"session":"s","created":0,"event":"pane_closed","id":"t1","exit":0}"#)
        guard case .paneClosed("t1", 0) = closed.event else { return XCTFail() }

        let notice = try decode(#"{"seq":5,"session":"s","created":0,"event":"pane_notice","id":"p1","level":"warn","message":"3 console errors"}"#)
        guard case .paneNotice(_, "warn", "3 console errors") = notice.event else { return XCTFail() }

        // A checkpoint record, by shape.
        let check = try decode(#"{"seq":6,"session":"s","created":0,"event":"pane_checkpoint","turn":4,"path":"panes/turn-4.png"}"#)
        guard case .paneCheckpoint(4, "panes/turn-4.png") = check.event else { return XCTFail() }

        // Unknown events still decode.
        let other = try decode(#"{"seq":7,"session":"s","created":0,"event":"something_new","x":1}"#)
        guard case .unknown("something_new") = other.event else { return XCTFail() }
    }
}

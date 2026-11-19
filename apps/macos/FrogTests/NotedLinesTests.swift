import SwiftUI
import XCTest
@testable import Frog

/// The notes Frog keeps and uses (docs/customize-events.md, "Noted" and "Used notes"; canvas M2):
/// "Noted for pond" under the reply with Undo and Make it a rule, the Note call that kept it not
/// drawn as a step, and "Used N notes" with the lines that came back.
@MainActor
final class NotedLinesTests: XCTestCase {
    private var seq: UInt64 = 0
    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"s","created":1790000000000,"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private func conversation() -> Conversation {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-noted"), link: nil, replay: false, session: "s")
        send(c, #""turn_started","turn":1,"input":"no, we use pnpm here, never npm""#)
        send(c, #""item_started","id":"call_9","kind":{"type":"tool_call","name":"Note","arg":"Use pnpm here, never npm."}"#)
        send(c, #""item_completed","id":"call_9","item":{"type":"tool_call","name":"Note","arg":"Use pnpm here, never npm.","input":{},"outcome":"ok","output":"Noted.","display":null}"#)
        return c
    }
    private static let noted = #""noted","item":"call_9","turn":1,"id":"n_4","text":"Use pnpm here, never npm.","scope":"project","place":"pond","source":"correction","undo":"u_n4""#
    private static let used = #""used_notes","turn":1,"tokens":24,"notes":[{"id":"n_1","scope":"project","text":"Tests run with cargo nextest."},{"id":"n_2","scope":"everywhere","text":"Keep replies short."}]"#

    func testNotedAndUsedNotesLandOnTheirTurn() throws {
        let c = conversation()
        send(c, Self.noted)
        send(c, Self.used)
        let turn = try XCTUnwrap(c.turns.last)
        XCTAssertEqual(turn.noted?.note.id, "n_4")
        XCTAssertEqual(turn.noted?.note.undo, "u_n4")
        XCTAssertEqual(NotedLineView.lead(try XCTUnwrap(turn.noted)), "Noted for pond")
        XCTAssertEqual(turn.usedNotes.map(\.text), ["Tests run with cargo nextest.", "Keep replies short."])
        XCTAssertEqual(UsedNotesView.head(2), "Used 2 notes")
        XCTAssertEqual(UsedNotesView.head(1), "Used 1 note")
        // None came back: nothing to say.
        let quiet = conversation()
        send(quiet, #""used_notes","turn":1,"tokens":0,"notes":[]"#)
        XCTAssertTrue(quiet.turns.last?.usedNotes.isEmpty ?? false)
    }

    func testTheNoteCallIsntAStepOnceItsNoteDraws() throws {
        let c = conversation()
        let flows = FlowCache()
        let steps = { (t: TurnState) in flows.segments(of: t, showThinking: true).flatMap { s -> [String] in
            if case .activity(let g) = s { g.steps.map(\.id) } else { [] }
        } }
        XCTAssertEqual(steps(try XCTUnwrap(c.turns.last)), ["call_9"], "before noted, the call is a step")
        send(c, Self.noted)
        XCTAssertEqual(steps(try XCTUnwrap(c.turns.last)), [], "the noted line stands in for it, with the cache warm")
    }

    func testTheNoteCallLeavesItsGroupToo() throws {
        let c = conversation()
        send(c, #""item_started","id":"call_2","kind":{"type":"tool_call","name":"Read","arg":"package.json"}"#)
        send(c, #""item_completed","id":"call_2","item":{"type":"tool_call","name":"Read","arg":"package.json","input":{},"outcome":"ok","output":"{}","display":null}"#)
        let flows = FlowCache()
        let group = { (t: TurnState) -> TurnFlow.Segment? in flows.segments(of: t, showThinking: true).first }
        let before = try XCTUnwrap(group(try XCTUnwrap(c.turns.last)))
        send(c, Self.noted)
        let after = try XCTUnwrap(group(try XCTUnwrap(c.turns.last)))
        guard case .activity(let g) = after else { return XCTFail("still a group") }
        XCTAssertEqual(g.steps.map(\.id), ["call_2"])
        // The row compares by its stamp: it has to change, or the row keeps showing the call.
        XCTAssertNotEqual(before.stamp, after.stamp)
    }

    func testMakeItARulesCardWaitsAfterTheTurnAndItsReceiptLands() throws {
        let c = conversation()
        send(c, Self.noted)
        send(c, #""turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#)
        let rule = #"{"kind":"line","title":"Make this a rule?","change":{"new":"Use pnpm here, never npm."},"where":"In pond, in AGENTS.md","primary":"Add rule","dismiss":"Not now"}"#
        send(c, #""permission_request","id":"p_9","item":"note:n_4","name":"Customize","arg":"Make this a rule?","always":"","proposal":\#(rule)"#)
        let p = try XCTUnwrap(c.permission)
        XCTAssertEqual(p.proposal?.primary, "Add rule")
        XCTAssertTrue(c.drawsProposalLoose(p), "no row is note:n_4: the card waits after the turn")
        send(c, #""permission_resolved","id":"p_9","decision":"allow""#)
        send(c, #""customize_applied","item":"note:n_4","undo":"u_r1","card":\#(rule)"#)
        let receipt = try XCTUnwrap(c.turns.last?.items.first { $0.id == "note:n_4" }?.applied)
        XCTAssertEqual(AppliedLineView.verb(receipt.card, undone: false), "Remembered")
        // A card on a call of the turn draws on that call, not after the turn.
        send(c, #""item_started","id":"call_3","kind":{"type":"tool_call","name":"Customize","arg":"Remember this?"}"#)
        send(c, #""permission_request","id":"p_10","item":"call_3","name":"Customize","arg":"Remember this?","always":"","proposal":\#(rule)"#)
        XCTAssertFalse(c.drawsProposalLoose(try XCTUnwrap(c.permission)))
    }

    func testUndoAnswersOnTheNote() throws {
        let c = conversation()
        send(c, Self.noted)
        send(c, #""customize_undone","undo":"u_n4","ok":true"#)
        let noted = try XCTUnwrap(c.turns.last?.noted)
        XCTAssertEqual(noted.undone, .init(ok: true, message: nil))
        XCTAssertEqual(NotedLineView.lead(noted), "Forgot for pond")
    }

    func testMakeItARuleOnTheWire() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Op.noteToRule(id: "n_4", scope: "project"))) as? [String: Any])
        XCTAssertEqual(json as NSDictionary, ["op": "note_to_rule", "id": "n_4", "scope": "project"])
        // Held off with Customize, and never for a session another session started.
        XCTAssertFalse(ClientCaps.notes)
        XCTAssertFalse(ClientCaps.notes(top: true))
        XCTAssertFalse(ClientCaps.notes(top: false, enabled: true))
        let on = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Op.setClientCaps(panes: false, ask: true, notes: ClientCaps.notes(top: true, enabled: true)))) as? [String: Any])
        XCTAssertEqual(on as NSDictionary, ["op": "set_client_caps", "panes": false, "ask": true, "notes": true])
        let off = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Op.setClientCaps(panes: false, ask: true, notes: ClientCaps.notes(top: true)))) as? [String: Any])
        XCTAssertNil(off["notes"])
    }

    /// The lines as drawn, for review: `TEST_RUNNER_FROG_NOTED_OUT=<dir>`.
    func testRenderTheLines() throws {
        guard let out = ProcessInfo.processInfo.environment["FROG_NOTED_OUT"] else { throw XCTSkip("set TEST_RUNNER_FROG_NOTED_OUT to draw them") }
        let c = conversation()
        send(c, Self.noted)
        send(c, Self.used)
        send(c, #""turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#)
        let turn = try XCTUnwrap(c.turns.last)
        let view = VStack(alignment: .leading, spacing: 12) {
            NotedLineView(noted: turn.noted!, conversation: c)
            UsedNotesView(notes: turn.usedNotes)
        }
        .padding(32).frame(width: 784).background(Tokens.canvas).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let image = try XCTUnwrap(r.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(out)/noted-mac.png"))
    }
}

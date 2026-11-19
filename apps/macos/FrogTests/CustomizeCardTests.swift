import SwiftUI
import XCTest
@testable import Frog

/// Customize from the conversation (docs/customize-events.md; canvas N7 Remember, N9 Change): the
/// card a change waits on (`permission_request` with a `proposal`), the receipt with Undo once it's
/// made (`customize_applied`, then `customize_undone`), the app's settings changed by
/// `setting_change`, and the caps that let the engine offer the tool only to an app that draws it.
@MainActor
final class CustomizeCardTests: XCTestCase {
    private var seq: UInt64 = 0
    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"s","created":1790000000000,"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private func conversation() -> Conversation {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-customize"), link: nil, replay: false, session: "s")
        send(c, #""turn_started","turn":1,"input":"no, we use pnpm here, never npm""#)
        send(c, #""item_started","id":"call_3","kind":{"type":"tool_call","name":"Customize","arg":"Remember this?"}"#)
        return c
    }
    private static let remember = #"{"kind":"line","title":"Remember this?","change":{"new":"Use pnpm in this project, never npm."},"where":"In pond, in AGENTS.md, so your team gets it too","tokens_per_turn":12,"primary":"Remember","dismiss":"Not now","alternative":{"id":"notes","label":"Keep it just for me","where":"Frog's notes for pond, only you","tokens_per_turn":12},"asked_by":{"who":"frog","words":"no, we use pnpm here, never npm"}}"#

    func testTheCardIsTheApprovalWithAProposal() throws {
        let c = conversation()
        send(c, #""permission_request","id":"p_81","item":"call_3","name":"Customize","arg":"Remember this?","always":"","proposal":\#(Self.remember)"#)
        let p = try XCTUnwrap(c.permission?.proposal)
        XCTAssertEqual(p.title, "Remember this?")
        XCTAssertEqual(p.change.new, "Use pnpm in this project, never npm.")
        XCTAssertEqual(p.tokensPerTurn, 12)
        XCTAssertEqual(p.alternative?.id, "notes")
        XCTAssertEqual(p.askedBy?.who, "frog")
        XCTAssertEqual(ProposalCardView.whereLine(p.where, tokens: p.tokensPerTurn),
                       "In pond, in AGENTS.md, so your team gets it too. Adds 12 tokens to each turn.")
    }

    func testAChangeMadeIsAReceiptOnItsCallAndUndoAnswersOnIt() throws {
        let c = conversation()
        send(c, #""customize_applied","item":"call_3","undo":"u_5c1","card":\#(Self.remember)"#)
        let item = try XCTUnwrap(c.turns.last?.items.first { $0.id == "call_3" })
        let applied = try XCTUnwrap(item.applied)
        XCTAssertEqual(applied.undo, "u_5c1")
        XCTAssertEqual(AppliedLineView.verb(applied.card, undone: false), "Remembered")
        XCTAssertEqual(AppliedLineView.what(applied.card), "Use pnpm in this project, never npm.")
        // A receipt never folds away with quiet steps: it carries Undo.
        let quiet = (1...4).map { n -> ItemState in
            var s = ItemState(id: "r\(n)", kind: .tool(name: "Read", arg: "a\(n)")); s.done = true; return s
        }
        let runs = StepRuns.of(Array(quiet.prefix(2)) + [item] + Array(quiet.suffix(2)))
        XCTAssertTrue(runs.contains { if case .step(let s) = $0 { s.id == "call_3" } else { false } }, "the receipt is its own line")
        send(c, #""customize_undone","undo":"u_5c1","ok":false,"message":"The file changed since; nothing was undone.""#)
        XCTAssertEqual(c.turns.last?.items.first { $0.id == "call_3" }?.applied?.undone, .init(ok: false, message: "The file changed since; nothing was undone."))
    }

    func testASettingsCardAndReceiptReadOldToNew() throws {
        let card = #"{"kind":"setting","title":"Change Density","change":{"old":"Comfortable","new":"Compact"},"where":"Settings, on this device","primary":"Change","dismiss":"Not now","asked_by":{"who":"user","words":"make it compact"}}"#
        let c = conversation()
        send(c, #""customize_applied","item":"call_3","undo":"u_1","card":\#(card)"#)
        let applied = try XCTUnwrap(c.turns.last?.items.first { $0.id == "call_3" }?.applied)
        XCTAssertEqual(AppliedLineView.verb(applied.card, undone: false), "Changed")
        XCTAssertEqual(AppliedLineView.what(applied.card), "Density to Compact")
    }

    func testASettingChangeReachesTheAppAndLandsOnSettingsOwnKeys() throws {
        var got: [(String, JSONValue)] = []
        let had = Conversation.applySetting
        Conversation.applySetting = { got.append(($0, $1)) }
        defer { Conversation.applySetting = had }
        let c = conversation()
        send(c, #""setting_change","id":"density","value":"compact""#)
        XCTAssertEqual(got.map(\.0), ["density"])
        XCTAssertEqual(got.first?.1, .string("compact"))

        let suite = "frog-customize-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CustomizeSettings.apply("density", .string("compact"), defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "density"), "compact")
        XCTAssertTrue(CustomizeSettings.apply("sounds", .bool(true), defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: "playfulSounds") as? Bool, true)
        XCTAssertTrue(CustomizeSettings.apply("detail", .string("quiet"), defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: Verbosity.key), "quiet")
        XCTAssertFalse(CustomizeSettings.apply("density", .string("huge"), defaults: defaults), "not one of the row's options")
        XCTAssertFalse(CustomizeSettings.apply("monthly-cap", .string("10"), defaults: defaults), "not one this app takes without a card")
        XCTAssertEqual(CustomizeSettings.current(defaults)["density"], .string("compact"))
    }

    /// The sidebar's waiting line is the card's own question, not "Allow Customize Remember this??".
    func testTheSidebarAsksTheCardsQuestion() {
        XCTAssertEqual(AskPhrase.line(name: "Customize", arg: "Remember this?"), "Remember this?")
        XCTAssertEqual(AskPhrase.line(name: "Customize", arg: "Change Density"), "Change Density?")
    }

    /// The card and the receipt as drawn, for review: `TEST_RUNNER_FROG_CUSTOMIZE_OUT=<dir>`.
    func testRenderTheCardAndTheReceipt() throws {
        guard let out = ProcessInfo.processInfo.environment["FROG_CUSTOMIZE_OUT"] else { throw XCTSkip("set TEST_RUNNER_FROG_CUSTOMIZE_OUT to draw them") }
        let c = conversation()
        send(c, #""permission_request","id":"p_81","item":"call_3","name":"Customize","arg":"Remember this?","always":"","proposal":\#(Self.remember)"#)
        let card = #"{"kind":"setting","title":"Change Density","change":{"old":"Comfortable","new":"Compact"},"where":"Settings, on this device","primary":"Change","dismiss":"Not now","asked_by":{"who":"user","words":"make it compact"}}"#
        let applied = CustomizeApplied(undo: "u_1", card: try JSONDecoder.frog.decode(Proposal.self, from: Data(card.utf8)))
        let view = VStack(alignment: .leading, spacing: 16) {
            AppliedLineView(applied: applied, conversation: c)
            ProposalCardView(request: c.permission!, proposal: c.permission!.proposal!, conversation: c)
        }
        .padding(32).frame(width: 784).background(Tokens.canvas).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let image = try XCTUnwrap(r.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(out)/customize-mac.png"))
    }

    func testTheOpsAndCapsOnTheWire() throws {
        func json(_ op: Op) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any]) }
        XCTAssertEqual(try json(.undo("u_5c1")) as NSDictionary, ["op": "undo", "undo": "u_5c1"])
        XCTAssertEqual(try json(.permission(id: "p_81", decision: .allow, choice: "notes")) as NSDictionary, ["op": "permission", "id": "p_81", "decision": "allow", "choice": "notes"])
        XCTAssertEqual(try json(.setClientCaps(panes: false, ask: true, customize: true)) as NSDictionary, ["op": "set_client_caps", "panes": false, "ask": true, "customize": true])
    }

    /// Off until the engine's Customize path passes review, and never for a session another
    /// session started: the links send `customize` only through `ClientCaps`.
    func testNoAppTellsTheEngineAboutCustomizeYet() throws {
        func json(_ op: Op) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any]) }
        XCTAssertFalse(ClientCaps.customize)
        XCTAssertFalse(ClientCaps.customize(top: true))
        XCTAssertNil(try json(.setClientCaps(panes: true, ask: true, sessions: true, customize: ClientCaps.customize(top: true)))["customize"])
        XCTAssertTrue(ClientCaps.customize(top: true, enabled: true))
        XCTAssertFalse(ClientCaps.customize(top: false, enabled: true), "a child session has no one to click the card")
    }

    /// Every allow on a Customize card names its choice: "primary" (the button, ⌘↩, the sidebar,
    /// a notification) or the alternative's exact id; never "always", and a plain card never.
    func testEveryAllowNamesItsChoice() throws {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-customize"), link: link, replay: false, session: "s")
        let ask = { [self] (id: String) in send(c, #""permission_request","id":"\#(id)","item":"call_3","name":"Customize","arg":"Remember this?","always":"","proposal":\#(Self.remember)"#) }
        ask("p1"); c.answer(.allow)
        XCTAssertEqual(link.sent.last?["choice"] as? String, "primary")
        ask("p2"); c.answer(.allow, choice: "notes")
        XCTAssertEqual(link.sent.last?["choice"] as? String, "notes")
        ask("p3"); c.answer(.allowAlways)
        XCTAssertEqual(link.sent.last?["decision"] as? String, "allow")
        XCTAssertEqual(link.sent.last?["choice"] as? String, "primary")
        ask("p4"); c.answer(.allow, choice: "bogus")
        XCTAssertNil(link.sent.last?["choice"], "not on the card: no choice, so the engine changes nothing")
        ask("p5"); c.answer(.deny)
        XCTAssertNil(link.sent.last?["choice"])
        send(c, #""permission_request","id":"p6","item":"b1","name":"Bash","arg":"ls","always":"""#)
        c.answer(.allow, choice: "primary")
        XCTAssertNil(link.sent.last?["choice"], "a plain card has no choice")
    }

    /// A Frog Cloud session is top-level for the capability gate only when the list says so: listed
    /// with no `parent`. A child, or one the list doesn't have, gets no capability.
    func testACloudSessionIsTopLevelOnlyWhenTheListSaysSo() throws {
        let json = #"[{"id":"top","title":"a","repo":"r","branch":"main","state":"running","updated":1},{"id":"kid","title":"b","repo":"r","branch":"main","state":"running","updated":1,"parent":"top"}]"#
        let list = try JSONDecoder().decode([CloudGateway.Session].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.parent), [nil, "top"])
        XCTAssertTrue(CloudSessions.isTop("top", in: list))
        XCTAssertFalse(CloudSessions.isTop("kid", in: list))
        XCTAssertFalse(CloudSessions.isTop("unknown", in: list), "parentage unknown: a child")
        XCTAssertFalse(ClientCaps.customize(top: CloudSessions.isTop("kid", in: list), enabled: true))
    }

    /// Only the person's own click answers a Customize card: no chief or parent session may.
    func testACustomizeCardIsNeverDecidedForThePerson() throws {
        let c = conversation()
        send(c, #""permission_request","id":"p_81","item":"call_3","name":"Customize","arg":"Remember this?","always":"","proposal":\#(Self.remember)"#)
        XCTAssertTrue(SessionBroker.personal(tool: "Customize", pending: nil))
        XCTAssertTrue(SessionBroker.personal(tool: "Bash", pending: c.permission), "a card with a proposal, whatever it's called")
        XCTAssertFalse(SessionBroker.personal(tool: "Bash", pending: nil))
    }
}

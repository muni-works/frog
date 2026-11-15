import AppKit
import XCTest
import UserNotifications
@testable import Frog

/// Notifications are the model's call, not the app's: a finished turn never alerts, an
/// `attention` note bounces the Dock only when frog is behind another app, and a live `notify`
/// reaches the platform's effects exactly once.
@MainActor
final class NotifierTests: XCTestCase {
    /// Records what the Mac would do with a conversation's events.
    private final class Recorder: ConversationEffects {
        var notes: [NotifyNote] = []
        var turns = 0
        func turnEnded(_ c: Conversation, turn: TurnState) { turns += 1 }
        func asked(_ c: Conversation, _ request: PermissionRequest) {}
        func answered(_ c: Conversation, permission id: String) {}
        func live(_ c: Conversation, running: Bool, waiting: Bool) {}
        func notified(_ c: Conversation, _ note: NotifyNote) { notes.append(note) }
    }

    private var recorder: Recorder!
    private var saved: ConversationEffects?

    override func setUp() async throws {
        saved = Conversation.effects
        recorder = Recorder()
        Conversation.effects = recorder
    }

    override func tearDown() async throws {
        Conversation.effects = saved
    }

    private func envelope(_ seq: UInt64, created: Int64? = nil, _ body: String) throws -> Envelope {
        let ms = created ?? Int64(Date().timeIntervalSince1970 * 1000)
        return try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":\#(ms),\#(body)}"#.utf8))
    }

    func testAttentionBouncesOnlyWhenFrogIsNotFrontmost() {
        // Frontmost: they're looking at it. A bounce would be a hop for nothing.
        XCTAssertFalse(Notifier.wantsAttention(frontmost: true))
        XCTAssertTrue(Notifier.wantsAttention(frontmost: false))
    }

    /// The model's `Notify` reaches the platform once, with its urgency intact.
    func testALiveNotifyReachesTheEffects() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"notify","title":"build","body":"The build finished.","urgency":"attention""#))
        XCTAssertEqual(recorder.notes, [NotifyNote(title: "build", body: "The build finished.", urgency: .attention)])
        // A silent one is still news for the transcript, and the platform decides not to
        // interrupt; the effect still hears it, so a client can log or badge it.
        link.onEvent(try envelope(3, #""event":"notify","body":"All green.","urgency":"silent""#))
        XCTAssertEqual(recorder.notes.last, NotifyNote(title: nil, body: "All green.", urgency: .silent))
    }

    /// A turn ending is not a notification: no `Notify` event means no effect, which is the
    /// "pushing every response" fix asserted at the seam the Mac used to alert from.
    func testATurnEndingAlertsNothing() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false, session: "s")
        link.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"go""#))
        link.onEvent(try envelope(2, #""event":"item_started","id":"m","kind":{"type":"message"}"#))
        link.onEvent(try envelope(3, #""event":"item_completed","id":"m","item":{"type":"message","text":"All done."}"#))
        link.onEvent(try envelope(4, #""event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}"#))
        XCTAssertEqual(recorder.turns, 1, "the turn did end, live")
        XCTAssertTrue(recorder.notes.isEmpty, "a finished reply is already on screen")
    }

    /// Reopened history never re-alerts for something that happened hours ago.
    func testAReplayedNotifyIsNotNews() throws {
        let link = LiveLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: true, session: "s")
        // Old by the clock, and the session is replaying: both say "not news".
        link.onEvent(try envelope(1, created: 1_000, #""event":"notify","body":"hours ago","urgency":"attention""#))
        XCTAssertTrue(recorder.notes.isEmpty)
    }

    /// The urgencies the wire carries, and the mapping each platform applies.
    func testUrgenciesRoundTripOnTheWire() {
        for (raw, urgency) in [("attention", NotifyUrgency.attention), ("done", .done), ("silent", .silent)] {
            XCTAssertEqual(NotifyNote(title: "t", body: "b", urgency: urgency).urgency.rawValue, raw)
            XCTAssertEqual(NotifyUrgency(rawValue: raw), urgency)
        }
        XCTAssertNil(NotifyUrgency(rawValue: "loud"))
    }

    /// The categories a notification carries must be registered, or its buttons vanish and the
    /// banner is plain. (Read from the registration itself: the system's read-back is empty in
    /// a test host, which has no signed bundle to hold it.)
    func testTheCategoriesAreRegistered() {
        let categories = Notifier.categories()
        let names = Set(categories.map(\.identifier))
        for expected in ["PERMISSION", "ASK", "NOTIFY", "DONE", "permission"] {
            XCTAssertTrue(names.contains(expected), "\(expected) isn't registered; got \(names.sorted())")
        }
        // A permission banner without its actions can't be answered from Notification Center,
        // which is the whole point of the category.
        for id in ["PERMISSION", "permission"] {
            let actions = categories.first { $0.identifier == id }?.actions.map(\.identifier) ?? []
            XCTAssertEqual(Set(actions), ["allow", "deny"], "\(id) lost its Allow / Deny")
        }
    }

    /// The phone's payload for each urgency: NOTIFY, the interruption level, and no sound at
    /// all for `silent` (which is what makes it not interrupt).
    func testThePhonePayloadMapsUrgency() throws {
        func aps(_ urgency: NotifyUrgency) throws -> [String: Any] {
            let payload = try XCTUnwrap(RemotePush.notifyPayload(
                title: "build", body: "The build finished.", urgency: urgency, folder: "repo", session: "s"))
            XCTAssertEqual(payload["session"] as? String, "s")
            return try XCTUnwrap(payload["aps"] as? [String: Any])
        }
        let loud = try aps(.attention)
        XCTAssertEqual(loud["category"] as? String, "NOTIFY")
        XCTAssertEqual(loud["interruption-level"] as? String, "time-sensitive")
        XCTAssertEqual(loud["sound"] as? String, "default")
        XCTAssertEqual((loud["alert"] as? [String: Any])?["subtitle"] as? String, "frog in repo")

        let done = try aps(.done)
        XCTAssertEqual(done["interruption-level"] as? String, "active")
        XCTAssertEqual(done["sound"] as? String, "default")

        let silent = try aps(.silent)
        XCTAssertEqual(silent["interruption-level"] as? String, "passive")
        XCTAssertNil(silent["sound"], "silent must carry no sound: that's the whole point")

        // An empty body is never sent (there'd be nothing to read).
        XCTAssertNil(RemotePush.notifyPayload(title: "t", body: "  ", urgency: .done, folder: nil, session: "s"))
    }

    /// The away badge clears when frog comes forward.
    func testFocusClearsTheAwayBadge() {
        Notifier.shared.focus()
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    /// A malformed or empty FROG_PUSH_RELAY falls back to the default relay, never crashes.
    func testABadRelayOverrideFallsBack() {
        XCTAssertEqual(RemotePush.relay(nil), RemotePush.defaultRelay)
        XCTAssertEqual(RemotePush.relay(""), RemotePush.defaultRelay)
        XCTAssertEqual(RemotePush.relay("not a url"), RemotePush.defaultRelay)
        XCTAssertEqual(RemotePush.relay("http://localhost:8787/push"), URL(string: "http://localhost:8787/push"))
    }
}

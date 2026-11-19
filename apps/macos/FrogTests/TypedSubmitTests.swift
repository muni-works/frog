import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// `Op.submit`'s `typed`: only what the person typed in the composer is their own words to the
/// engine. The app's own prompts (git actions, starters, replays) go untyped, and a queued turn
/// keeps each message's own flag. Also: cloud links offer no Customize caps unless the session is
/// known to have no parent.
@MainActor
final class TypedSubmitTests: XCTestCase {
    private func json(_ op: Op) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return String(decoding: try enc.encode(op), as: UTF8.self)
    }

    /// An idle conversation over a recording link.
    private func idle() throws -> (Conversation, QueueLink) {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-typed"), link: link, replay: false)
        try link.event(#""event":"idle""#)
        return (c, link)
    }

    // MARK: - Wire

    func testTypedIsOnTheWireOnlyWhenTrue() throws {
        XCTAssertEqual(try json(.submit("a")), #"{"op":"submit","text":"a"}"#)
        XCTAssertEqual(try json(.submit("a", typed: false)), #"{"op":"submit","text":"a"}"#)
        XCTAssertEqual(try json(.submit("a", typed: true)), #"{"op":"submit","text":"a","typed":true}"#)
    }

    func testEachPartCarriesItsOwnTyped() throws {
        let op = Op.submit("a", more: [MessagePart(text: "b"), MessagePart(text: "c", typed: true)], typed: true)
        XCTAssertEqual(try json(op), #"{"more":[{"text":"b"},{"text":"c","typed":true}],"op":"submit","text":"a","typed":true}"#)
    }

    func testAPartWithoutTypedDecodesUntyped() throws {
        let part = try JSONDecoder().decode(MessagePart.self, from: Data(#"{"text":"b"}"#.utf8))
        XCTAssertFalse(part.typed)
        let typed = try JSONDecoder().decode(MessagePart.self, from: Data(#"{"text":"b","typed":true}"#.utf8))
        XCTAssertTrue(typed.typed)
    }

    // MARK: - Conversation

    func testSubmitIsUntypedUnlessTold() throws {
        let (c, link) = try idle()
        c.submit("Commit the current changes")
        XCTAssertEqual(link.sent.last?["op"] as? String, "submit")
        XCTAssertNil(link.sent.last?["typed"], "the app's own prompt")
        try link.event(#""event":"idle""#)
        c.submit("make the font bigger", typed: true)
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
    }

    func testATypedMemoryCommandStaysTyped() throws {
        let (c, link) = try idle()
        c.submit("/remember tabs, not spaces", typed: true)
        XCTAssertEqual(link.sent.last?["text"] as? String, "/remember tabs, not spaces")
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
    }

    /// Queued sends go as one turn; each keeps its own flag and none borrows another's.
    func testTheQueueKeepsEachMessagesOwnFlag() throws {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-typed"), link: link, replay: false)
        c.submit("Fix the failing checks on #3")  // a git action, queued first
        c.submit("and remember tabs", typed: true)
        c.submit("Push this branch")
        try link.event(#""event":"idle""#)
        let sent = try XCTUnwrap(link.sent.last)
        XCTAssertEqual(sent["text"] as? String, "Fix the failing checks on #3")
        XCTAssertNil(sent["typed"], "the head is the app's: not promoted by a typed part")
        let more = try XCTUnwrap(sent["more"] as? [[String: Any]])
        XCTAssertEqual(more.map { $0["text"] as? String }, ["and remember tabs", "Push this branch"])
        XCTAssertEqual(more.map { $0["typed"] as? Bool }, [true, nil])
    }

    func testATypedHeadAloneStaysTyped() throws {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-typed"), link: link, replay: false)
        c.submit("then run the tests", typed: true)
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
        XCTAssertNil(link.sent.last?["more"])
    }

    // MARK: - A cloud session's first message

    func testACloudStartCarriesItsFlagAndTryAgainDoesNot() throws {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-typed"), link: link, replay: false)
        c.open(CloudStart(text: "remember tabs", repo: nil, typed: true))
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
        c.resendStart()  // Try again: the message as it was, the app's resend
        XCTAssertNil(link.sent.last?["typed"])
        c.resendStart("remember spaces", typed: true)  // typed instead
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
        XCTAssertEqual(link.sent.last?["text"] as? String, "remember spaces")
    }

    func testAnUntypedCloudStartGoesUntyped() {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-typed"), link: link, replay: false)
        c.open(CloudStart(text: "a starter", repo: nil))
        XCTAssertNil(link.sent.last?["typed"])
    }

    // MARK: - The composer

    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 820)))
        host.frame = CGRect(x: 0, y: 0, width: 820, height: host.fittingSize.height)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderInForTest()
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        return (w, host)
    }

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func textView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// Typed into the real composer and sent with Return: typed. While a turn runs, the queued
    /// send is typed too.
    func testTheComposersSendIsTyped() throws {
        let ws = Workspace(folder: URL(fileURLWithPath: "/tmp/frog-typed"), fresh: true)
        let (c, link) = try idle()
        let (w, host) = host(ComposerView(workspace: ws, conversation: c))
        defer { w.close() }
        let tv = try XCTUnwrap(Self.textView(in: host))

        tv.insertText("make the font bigger", replacementRange: tv.selectedRange())
        pump(0.3)
        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.3)
        let first = try XCTUnwrap(link.sent.last { $0["op"] as? String == "submit" })
        XCTAssertEqual(first["text"] as? String, "make the font bigger")
        XCTAssertEqual(first["typed"] as? Bool, true)

        // The turn runs: the next send queues, and goes typed when it ends.
        let count = link.sent.count
        tv.insertText("and remember tabs", replacementRange: tv.selectedRange())
        pump(0.3)
        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.3)
        XCTAssertEqual(c.queue.map(\.text), ["and remember tabs"])
        XCTAssertEqual(c.queue.map(\.typed), [true])
        XCTAssertEqual(link.sent.count, count, "nothing goes while the turn runs")
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.last?["text"] as? String, "and remember tabs")
        XCTAssertEqual(link.sent.last?["typed"] as? Bool, true)
    }

    // MARK: - Race

    func testARaceAttemptIsAChildAndNotAWorker() {
        var seen: (args: [String], model: String?, child: Bool)?
        _ = Race.attempt(in: URL(fileURLWithPath: "/tmp/frog-typed"), model: "m") { dir, args, model, child in
            seen = (args, model, child)
            return Conversation(folder: dir, link: QueueLink(), replay: false)
        }
        XCTAssertEqual(seen?.child, true, "no Customize caps for an attempt")
        XCTAssertEqual(seen?.model, "m")
        XCTAssertFalse(seen?.args.contains("--worker") ?? true)
    }

    // MARK: - Cloud links

    func testACloudLinkOffersNothingUnlessToldItIsTop() {
        let gateway = CloudGateway(token: "test")
        XCTAssertFalse(CloudLink(gateway: gateway, session: "s", connect: false).top, "unknown parentage: a child's")
        XCTAssertTrue(CloudLink(gateway: gateway, session: "s", connect: false, top: true).top)
        // With the caps switched on, the default still offers nothing.
        let link = CloudLink(gateway: gateway, session: "s", connect: false)
        XCTAssertFalse(ClientCaps.customize(top: link.top, enabled: true))
        XCTAssertFalse(ClientCaps.notes(top: link.top, enabled: true))
    }

    func testTheListDecidesWhoIsTop() throws {
        let list = try JSONDecoder().decode([CloudGateway.Session].self, from: Data("""
        [{"id":"mine","title":"t","repo":"","branch":"","state":"running","updated":1},
         {"id":"kid","title":"t","repo":"","branch":"","state":"running","updated":1,"parent":"mine"}]
        """.utf8))
        XCTAssertNil(list[0].parent)
        XCTAssertEqual(list[1].parent, "mine")
        XCTAssertTrue(CloudSessions.isTop("mine", in: list))
        XCTAssertFalse(CloudSessions.isTop("kid", in: list), "another session started it")
        XCTAssertFalse(CloudSessions.isTop("unlisted", in: list), "not listed yet: unknown, so no caps")
    }

    // MARK: - The phone, over the bridge

    /// The phone's composer goes through `RemoteLink`, which encodes FrogKit's `Op` to a dict:
    /// typed survives. Siri ("Ask frog …") and a notification's Reply build their own dicts
    /// with no typed, so the bridge submits them untyped.
    func testTheBridgeForwardsTypedOnlyFromThePhonesComposer() throws {
        let composer = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Op.submit("set density to compact", typed: true))) as? [String: Any])
        XCTAssertTrue(RemoteBridge.typed(composer))
        let untyped = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Op.submit("hi"))) as? [String: Any])
        XCTAssertFalse(RemoteBridge.typed(untyped))
        XCTAssertFalse(RemoteBridge.typed(["op": "submit", "text": "from Siri"]), "Intents.swift")
        XCTAssertFalse(RemoteBridge.typed(["op": "submit", "text": "from a reply"]), "Notifications.swift")
        XCTAssertFalse(RemoteBridge.typed(["op": "submit", "text": "x", "typed": "true"]), "only a real true")
    }

}

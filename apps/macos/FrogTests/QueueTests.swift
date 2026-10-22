import XCTest
@testable import Frog

/// Messages sent while a turn runs: taking one back out puts it in the composer.
@MainActor
final class QueueTests: XCTestCase {
    private let png = ToolImage(mime: "image/png", data: "AAAA")
    private let jpeg = ToolImage(mime: "image/jpeg", data: "BBBB")

    /// A conversation with a turn running (busy until the engine's first `idle`).
    private func running() -> (Conversation, QueueLink) {
        let link = QueueLink()
        return (Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false), link)
    }

    func testDismissingRestoresIntoAnEmptyDraft() {
        let (c, _) = running()
        c.submit("then run the tests")
        XCTAssertEqual(c.queue.count, 1)
        c.unqueue(at: 0)
        XCTAssertTrue(c.queue.isEmpty)
        let back = c.takeRestored(into: "", attachments: [])
        XCTAssertEqual(back.text, "then run the tests")
        XCTAssertEqual(back.images, [])
        XCTAssertTrue(c.restored.isEmpty, "taken once")
    }

    func testDismissingKeepsWhatIsTypedAfterABlankLine() {
        let (c, _) = running()
        c.submit("first thought")
        c.unqueue(at: 0)
        let back = c.takeRestored(into: "half-typed draft", attachments: [])
        XCTAssertEqual(back.text, "first thought\n\nhalf-typed draft")
        // A whitespace-only draft is nothing to keep.
        XCTAssertEqual(Conversation.Queued(text: "x").restore(into: "  \n", attachments: []).text, "x")
    }

    func testDismissingKeepsAttachments() {
        let (c, _) = running()
        c.submit("look at this", images: [png])
        c.unqueue(at: 0)
        let back = c.takeRestored(into: "and this", attachments: [jpeg])
        XCTAssertEqual(back.text, "look at this\n\nand this")
        XCTAssertEqual(back.images, [png, jpeg])
        // An image with no words comes back as just the image.
        c.submit("", images: [png])
        c.unqueue(at: 0)
        XCTAssertEqual(c.takeRestored(into: "", attachments: []).text, "")
    }

    func testDismissingOneLeavesTheRestQueued() {
        let (c, link) = running()
        c.submit("one")
        c.submit("two")
        c.submit("three")
        c.unqueue(at: 1)
        XCTAssertEqual(c.queue.map(\.text), ["one", "three"])
        XCTAssertEqual(c.restored.map(\.text), ["two"])
        XCTAssertTrue(link.sent.isEmpty, "nothing goes while the turn runs")
    }

    // MARK: Flushing at turn end

    private func texts(_ op: [String: Any]) -> [String] {
        [op["text"] as? String ?? ""] + ((op["more"] as? [[String: Any]]) ?? []).map { $0["text"] as? String ?? "" }
    }

    func testEverythingQueuedGoesAsOneTurnInOrder() throws {
        let (c, link) = running()
        c.submit("one")
        c.submit("two")
        c.submit("three", images: [png])
        try link.event(#""event":"idle""#)

        XCTAssertTrue(c.queue.isEmpty)
        XCTAssertEqual(link.sent.count, 1, "one turn, not three")
        let op = link.sent[0]
        XCTAssertEqual(op["op"] as? String, "submit")
        XCTAssertEqual(texts(op), ["one", "two", "three"])
        let more = op["more"] as? [[String: Any]] ?? []
        XCTAssertEqual((more.last?["images"] as? [[String: String]])?.first?["mime"], "image/png", "attachments kept")
        XCTAssertNil(more.first?["images"], "none sent where there were none")

        // Shown as the bubbles that were typed, in one turn, which the engine's start claims.
        XCTAssertEqual(c.turns.count, 1)
        XCTAssertEqual(c.turns[0].input, "one")
        XCTAssertEqual(c.turns[0].more, [MessagePart(text: "two"), MessagePart(text: "three", images: [png])])
        try link.event(#""event":"turn_started","turn":1,"input":"one","more":[{"text":"two"},{"text":"three","images":[{"mime":"image/png","data":"AAAA"}]}]"#)
        XCTAssertEqual(c.turns.count, 1)
        XCTAssertEqual(c.turns[0].number, 1)
        XCTAssertEqual(c.turns[0].request, "one\n\ntwo\n\nthree")
    }

    func testDismissedBeforeTheFlushStaysOut() throws {
        let (c, link) = running()
        c.submit("one")
        c.submit("two")
        c.submit("three")
        c.unqueue(at: 1)
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.map(texts), [["one", "three"]])
        XCTAssertEqual(c.takeRestored(into: "", attachments: []).text, "two", "still in the composer")
    }

    func testOneQueuedMessageGoesAsBefore() throws {
        let (c, link) = running()
        c.submit("just this")
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.count, 1)
        XCTAssertNil(link.sent[0]["more"])
        XCTAssertEqual(c.turns.last?.more, [])
    }

    func testCommandsCantJoinATurn() throws {
        let (c, link) = running()
        c.submit("!ls")
        c.submit("then this")
        c.submit("and this")
        c.submit("/remember tabs")
        c.submit("last")
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.map { $0["op"] as? String }, ["shell"])
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.last.map(texts), ["then this", "and this"])
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.last.map(texts), ["/remember tabs"])
        try link.event(#""event":"idle""#)
        XCTAssertEqual(link.sent.last.map(texts), ["last"])
        XCTAssertTrue(c.queue.isEmpty)
    }

    func testSubmitEncodesMoreOnlyWhenThere() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = { (op: Op) in String(decoding: try enc.encode(op), as: UTF8.self) }
        XCTAssertEqual(try json(.submit("a")), #"{"op":"submit","text":"a"}"#)
        XCTAssertEqual(try json(.submit("a", more: [MessagePart(text: "b"), MessagePart(text: "c", images: [png])])),
                       #"{"more":[{"text":"b"},{"images":[{"data":"AAAA","mime":"image\/png"}],"text":"c"}],"op":"submit","text":"a"}"#)
    }
}

/// Records each op as the engine would receive it (JSON).
@MainActor
final class QueueLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var sent: [[String: Any]] = []
    func send(_ op: Op) {
        guard let data = try? JSONEncoder().encode(op),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        sent.append(obj)
    }
    func stop() {}
    var endDescription: String { "" }

    private var seq: UInt64 = 0
    func event(_ body: String) throws {
        seq += 1
        onEvent(try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8)))
    }
}

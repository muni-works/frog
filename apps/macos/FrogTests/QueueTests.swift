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

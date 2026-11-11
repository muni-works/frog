import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Frog

/// The table transcript (`TableTranscript`, behind `TranscriptContainer.table`) against the lazy
/// stack: each behaviour checked in both containers, the same way. What isn't covered here is
/// listed in docs/plans/mac-transcript-table-2026-11-11.md.
@MainActor
final class TableTranscriptParityTests: XCTestCase {
    @Observable fileprivate final class JumpBox { var id: TurnState.ID? }
    private let jumpBox = JumpBox()
    private var visible: [TurnState.ID] = []
    private var seq: UInt64 = 0
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!

    private var container = TranscriptContainer.table
    override func setUp() async throws { container = TranscriptContainer.table }
    override func tearDown() async throws {
        window?.close()
        TranscriptContainer.table = container
        pump(0.1)
    }

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"t","created":1790113417019,"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private static func json(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
    private func views<T: NSView>(_ v: NSView, _: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, T.self) } }
    private var scroll: NSScrollView { views(host, NSScrollView.self).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }! }

    private func turn(_ c: Conversation, _ n: Int, answer: String? = nil) {
        send(c, #""turn_started","turn":\#(n),"input":\#(Self.json("Question \(n)"))"#)
        send(c, #""item_started","id":"tool-\#(n)","kind":{"type":"tool_call","name":"Bash","arg":"ls"}"#)
        send(c, #""item_completed","id":"tool-\#(n)","item":{"type":"tool_call","name":"Bash","arg":"ls","input":{"command":"ls"},"outcome":"ok","output":"ok","display":null}"#)
        let text = answer ?? "Answer \(n): a paragraph that wraps over a couple of lines in the window so rows have height.\n\n```swift\nlet x = \(n)\n```"
        send(c, #""item_started","id":"msg-\#(n)","kind":{"type":"message"}"#)
        send(c, #""item_completed","id":"msg-\#(n)","item":{"type":"message","text":\#(Self.json(text))}"#)
        send(c, #""turn_ended","turn":\#(n),"reason":{"type":"complete"},"usage":{"context_tokens":1,"input_tokens":1,"output_tokens":1,"model_calls":1,"tokens_per_sec":20}"#)
    }

    private func open(table: Bool, turns: Int) -> Conversation {
        TranscriptContainer.table = table
        TranscriptProbe.reset()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "t")
        for n in 0..<turns { turn(c, n + 1) }
        let box = jumpBox
        let view = TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }),
                                  jump: Binding(get: { box.id }, set: { box.id = $0 }),
                                  onVisibleTurns: { [weak self] in self?.visible = $0 })
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        pump(0.5)
        XCTAssertEqual(!views(host, NSTableView.self).isEmpty, table, "the container asked for is the one mounted")
        return c
    }

    private func atEnd() -> Bool {
        let s = scroll, clip = s.contentView.bounds
        return clip.maxY - s.contentInsets.bottom >= (s.documentView?.frame.height ?? 0) - 30
    }

    func testOpensAtTheEnd() {
        for table in [false, true] {
            let c = open(table: table, turns: 120)
            XCTAssertTrue(atEnd(), "table \(table): opens at the end")
            XCTAssertTrue(visible.contains(c.turns.last!.id), "table \(table): reports the last turn visible")
            window.close()
        }
    }

    func testOnlyRowsOnScreenAreBuilt() {
        for table in [false, true] {
            _ = open(table: table, turns: 300)
            XCTAssertLessThanOrEqual(TranscriptProbe.peakMountedRows, 30, "table \(table): virtualized")
            window.close()
        }
    }

    func testJumpShowsTheTurn() {
        for table in [false, true] {
            let c = open(table: table, turns: 200)
            let target = c.turns[40].id
            jumpBox.id = target
            pump(0.8)
            XCTAssertTrue(visible.contains(target), "table \(table): the jumped-to turn is on screen")
            XCTAssertFalse(atEnd(), "table \(table): a jump stops following")
            window.close()
        }
    }

    func testStreamingShowsWordsAndFollows() {
        for table in [false, true] {
            let c = open(table: table, turns: 30)
            send(c, #""turn_started","turn":99,"input":"go""#)
            send(c, #""item_started","id":"t99","kind":{"type":"tool_call","name":"Bash","arg":"ls"}"#)
            send(c, #""item_completed","id":"t99","item":{"type":"tool_call","name":"Bash","arg":"ls","input":{"command":"ls"},"outcome":"ok","output":"ok","display":null}"#)
            send(c, #""item_started","id":"live","kind":{"type":"message"}"#)
            for i in 0..<12 {
                send(c, #""item_delta","id":"live","delta":{"type":"text","text":"word\#(i) "}"#)
                pump(0.03)
            }
            send(c, #""item_delta","id":"live","delta":{"type":"text","text":"\n\nlast-line"}"#)
            pump(0.6)
            let text = views(host, MessageTextView.self).map(\.string).joined()
            XCTAssertTrue(text.contains("last-line"), "table \(table): the streamed words are drawn")
            XCTAssertTrue(atEnd(), "table \(table): follows a short answer to the end")
            window.close()
        }
    }

    func testResizeRelaysOutVisibleRows() {
        for table in [false, true] {
            _ = open(table: table, turns: 60)
            window.setContentSize(NSSize(width: 520, height: 700)); pump(0.4)
            let narrow = views(host, MessageTextView.self).filter { $0.window != nil && !$0.visibleRect.isEmpty }
            XCTAssertFalse(narrow.isEmpty, "table \(table): text on screen")
            XCTAssertTrue(narrow.allSatisfy { $0.frame.width <= 520 }, "table \(table): rows narrowed to the window")
            XCTAssertTrue(atEnd(), "table \(table): still at the end after a resize")
            window.close()
        }
    }
}

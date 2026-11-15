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

    /// Spin the run loop until `condition` holds, giving up after `timeout` (times `TestRunner.slack`
    /// on CI, whose runner is a loaded shared VM). A fixed `pump` is a guess at how long layout and
    /// following take; when the guess is wrong the assertion races it and fails on a slow runner, on
    /// unchanged code. These tests wait for the state they assert on instead, then assert it.
    @discardableResult
    private func wait(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout * TestRunner.slack)
        while Date() < deadline {
            if condition() { return true }
            pump(0.02)
        }
        return condition()
    }

    private static func json(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
    private func views<T: NSView>(_ v: NSView, _: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, T.self) } }
    /// The transcript's scroll view: the tallest one mounted. Nil before the first layout, which the
    /// waits below poll through, so they must not force-unwrap it.
    private var scrollView: NSScrollView? {
        views(host, NSScrollView.self).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

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
        // The container asked for, laid out and settled: every mounted row has a real height and
        // the view has opened at the end. Waiting for the first row alone is not enough — a table
        // still measuring its rows answers `rect(ofRow:)` from estimates, so a jump taken then
        // lands at the top and the test fails on correct code.
        let ready = wait() {
            let mountedTable = !self.views(self.host, NSTableView.self).isEmpty
            guard mountedTable == table,
                  let doc = self.scrollView?.documentView, doc.frame.height > 0 else { return false }
            let rows = self.views(self.host, MessageTextView.self)
            return !rows.isEmpty && rows.allSatisfy { !$0.frame.isEmpty } && self.atEnd()
        }
        XCTAssertTrue(ready, "the container asked for is the one mounted, settled at the end")
        return c
    }

    private func atEnd() -> Bool {
        guard let s = scrollView else { return false }
        let clip = s.contentView.bounds
        return clip.maxY - s.contentInsets.bottom >= (s.documentView?.frame.height ?? 0) - 30
    }

    /// Everything the transcript has drawn as message text, mounted rows joined.
    private func drawnText() -> String { views(host, MessageTextView.self).map(\.string).joined() }

    func testOpensAtTheEnd() {
        for table in [false, true] {
            let c = open(table: table, turns: 120)
            XCTAssertTrue(wait() { self.atEnd() }, "table \(table): opens at the end")
            XCTAssertTrue(wait() { self.visible.contains(c.turns.last!.id) },
                          "table \(table): reports the last turn visible")
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
            XCTAssertTrue(wait() { self.visible.contains(target) },
                          "table \(table): the jumped-to turn is on screen")
            XCTAssertTrue(wait() { !self.atEnd() }, "table \(table): a jump stops following")
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
                // Each delta drawn before the next is sent, so this is a stream and not one buffered
                // write: wait for the words so far rather than sleeping a guessed interval.
                wait(timeout: 5) { self.drawnText().contains("word\(i) ") }
            }
            send(c, #""item_delta","id":"live","delta":{"type":"text","text":"\n\nlast-line"}"#)
            XCTAssertTrue(wait() { self.drawnText().contains("last-line") },
                          "table \(table): the streamed words are drawn")
            XCTAssertTrue(wait() { self.atEnd() },
                          "table \(table): follows a short answer to the end")
            window.close()
        }
    }

    func testResizeRelaysOutVisibleRows() {
        for table in [false, true] {
            _ = open(table: table, turns: 60)
            window.setContentSize(NSSize(width: 520, height: 700))
            // Rows on screen, narrowed to the new width, and the view still following the end.
            XCTAssertTrue(wait() {
                let narrow = self.views(self.host, MessageTextView.self).filter { $0.window != nil && !$0.visibleRect.isEmpty }
                return !narrow.isEmpty && narrow.allSatisfy { $0.frame.width <= 520 } && self.atEnd()
            }, "table \(table): rows narrowed to the window")
            let narrow = views(host, MessageTextView.self).filter { $0.window != nil && !$0.visibleRect.isEmpty }
            XCTAssertFalse(narrow.isEmpty, "table \(table): text on screen")
            XCTAssertTrue(narrow.allSatisfy { $0.frame.width <= 520 }, "table \(table): rows narrowed to the window")
            XCTAssertTrue(atEnd(), "table \(table): still at the end after a resize")
            window.close()
        }
    }
}

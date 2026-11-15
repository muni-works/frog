import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The answer's words show as they stream, not only when the message completes. The live turn's
/// segments are cached between item boundaries (`FlowCache`), so the row that draws the answer
/// must read the streaming text from somewhere that changes (`ItemState.streamedText`).
@MainActor
final class StreamingTextTests: XCTestCase {
    private var seq: UInt64 = 0
    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"s","created":1790113417019,"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func texts(_ v: NSView) -> [MessageTextView] { ((v as? MessageTextView).map { [$0] } ?? []) + v.subviews.flatMap(texts) }

    private func streamedWords(live: Bool) -> String {
        Conversation.streamsLive = live
        defer { Conversation.streamsLive = true }
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "s")
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in })))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil)
        defer { w.close() }
        send(c, #""turn_started","turn":1,"input":"hi""#)
        send(c, #""item_started","id":"m","kind":{"type":"message"}"#)
        for word in ["Alpha ", "beta ", "gamma ", "delta ", "omega"] {
            send(c, #""item_delta","id":"m","delta":{"type":"text","text":"\#(word)"}"#)
            pump(0.03)
        }
        host.layoutSubtreeIfNeeded(); pump(0.1)
        return texts(host).map(\.string).joined(separator: "|")
    }

    /// On main before `LiveText`, the answer froze at its first delta ("Alpha ") until the
    /// message completed: the cached segment held the item as it was at the first word.
    func testAnswerShowsWordsWhileStreaming() {
        XCTAssertTrue(streamedWords(live: true).contains("omega"), "the last streamed word is in the answer's text view")
    }
}

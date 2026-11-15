import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The typing bubble mid-stream and its handoff to the plain row, rendered for review:
/// `$TMPDIR/frog-snapshots/typing-{writing,settled}.png`.
@MainActor
final class TypingBubbleSnapshotTests: XCTestCase {
    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        clock += 7
        let line = #"{"seq":\#(seq),"session":"bubble","created":\#(clock),"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRenderBubbleAndHandoff() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "bubble")
        send(c, #""turn_started","turn":1,"input":\#(Self.json("Fix the parser's offset handling"))"#)
        let id = "tool-1"
        send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Read","arg":"Parser.swift"}"#)
        send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Read","arg":"Parser.swift","input":{"file_path":"Parser.swift"},"outcome":"ok","output":"ok","display":null}"#)
        let text = "The offset came from the *reader's* frame, not the document's. Fixed:\n\n```swift\nlet offset = document.frame.origin\n```\n\nThe tests pass now."
        let id2 = "msg-1"
        send(c, #""item_started","id":"\#(id2)","kind":{"type":"message"}"#)
        send(c, #""item_delta","id":"\#(id2)","delta":{"type":"text","text":\#(Self.json(String(text.prefix(60))))}"#)
        send(c, #""status","model":"vercel/anthropic/claude-opus-5.5-fast","mode":"default","cwd":"/tmp/demo","messages":2,"context_window":200000,"tool_mode":"auto","tier":"cloud","tokens_per_sec":64.2,"todos":[]"#)
        pump(0.2)
        let view = TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .frame(width: 780, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 780, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        pump(0.4)
        host.layoutSubtreeIfNeeded()

        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            pump(0.2)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: name))
        }
        try capture("typing-writing.png")

        // The handoff: the rest of the answer arrives, the message completes, the turn ends.
        send(c, #""item_delta","id":"\#(id2)","delta":{"type":"text","text":\#(Self.json(String(text.dropFirst(60))))}"#)
        send(c, #""item_completed","id":"\#(id2)","item":{"type":"message","text":\#(Self.json(text))}"#)
        send(c, #""turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"context_tokens":2377,"input_tokens":13861,"output_tokens":470,"model_calls":2,"tokens_per_sec":61.8,"model":"vercel/anthropic/claude-opus-5.5-fast"}"#)
        send(c, #""idle""#)
        pump(0.5)
        try capture("typing-settled.png")
        XCTAssertEqual(c.turns.first?.items.count, 2)
    }
}

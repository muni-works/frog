import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The tool-row UX states, rendered for design review into `$TMPDIR/frog-snapshots/`:
/// a shell row with and without a gist, running with its timer, and the expanded
/// command view with its long-output fold.
@MainActor
final class CommandRowSnapshotTests: XCTestCase {
    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        clock += 7
        let line = #"{"seq":\#(seq),"session":"row","created":\#(clock),"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func conversation() -> Conversation {
        let root = "/Users/cam/Developer/frog/.frog/worktrees/sleep-events"
        let c = Conversation(folder: URL(fileURLWithPath: root), link: nil, replay: false, session: "row")
        send(c, #""turn_started","turn":1,"input":\#(Self.json("Check the branch"))"#)
        return c
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func render(_ name: String) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let view = TranscriptView(conversation: try XCTUnwrap(c), actions: TurnActions(fork: { _ in }, rewind: { _ in }))
        pump(0.5)
        let host = NSHostingView(rootView: view.frame(width: 780, height: 560).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(x: 0, y: 0, width: 780, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        pump(0.4)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: name))
    }

    private var c: Conversation?

    func testRenderRowStates() throws {
        let root = "/Users/cam/Developer/frog/.frog/worktrees/sleep-events"
        let conv = conversation()
        c = conv
        let cmd = "cd \(root) && git --no-optional-locks log --oneline -5 && git --no-optional-locks status --short"

        // 1. Pending: running, no gist yet — elided command, timer, streaming hint.
        send(conv, #""item_started","id":"b1","kind":{"type":"tool_call","name":"Bash","arg":\#(Self.json(cmd))}"#)
        send(conv, #""item_delta","id":"b1","delta":{"type":"output","text":"7faaf84 Merge pull request #103\n"}"#)
        try render("row-running.png")

        // 2. Done, gist arrived: the preview reads as intent.
        send(conv, #""item_completed","id":"b1","item":{"type":"tool_call","name":"Bash","arg":\#(Self.json(cmd)),"input":{"command":\#(Self.json(cmd))},"outcome":"ok","output":"7faaf84 Merge pull request #103\\n57ded26 engine: no side runs"}"#)
        send(conv, #""item_gisted","item":"b1","gist":"git log and status of the sleep-events worktree""#)
        pump(0.3)
        try render("row-gisted.png")

        // 3. Done, no gist (no side-model resolved): the elided command stays.
        send(conv, #""item_started","id":"b2","kind":{"type":"tool_call","name":"Bash","arg":\#(Self.json(cmd))}"#)
        send(conv, #""item_completed","id":"b2","item":{"type":"tool_call","name":"Bash","arg":\#(Self.json(cmd)),"input":{"command":\#(Self.json(cmd))},"outcome":"ok","output":"7faaf84 Merge"}"#)
        pump(0.3)
        try render("row-fallback.png")
    }
}

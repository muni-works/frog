import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The activity pill's churn benchmark: the toolbar's glass capsule (`ActivityViewer`) while a
/// turn runs, on screen, for a fixed 30 s window — the pill exactly as the app shows it (a 30/s
/// playful frog, the 60/s working line sweep, a 1/s elapsed clock), driven by a live
/// conversation fed real event JSON.
///
/// The export dedup caveat: strings dedupe by ref, so grepping an exported render stream lies.
/// Instead this counts what the code builds, through `PillProbe` (the DEBUG-counter pattern
/// `TranscriptProbe` established in #98): a body evaluated is a layout/invalidation pass —
/// churn shows up as bodies per minute, before any pixel is drawn.
///
///     xcodebuild test ... -only-testing:FrogTests/PillChurnBenchmarkTests/testBaseline
///
/// The window is fixed at 30 s. Prints `pill:` lines with per-minute numbers per variant.
@MainActor
final class PillChurnBenchmarkTests: XCTestCase {
    private static let seconds = 30.0

    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019
    private var turn = 0

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        clock += 7
        let line = #"{"seq":\#(seq),"session":"pill","created":\#(clock),"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// One step of a live turn: a tool call that runs a moment, streams some output (the
    /// newest line keeps landing, as a shell pane does) and completes; the next follows
    /// immediately, so the turn never ends inside the window.
    private func runStep(into c: Conversation) {
        turn += 1
        let id = "t\(turn)"
        send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
        send(c, #""item_delta","id":"\#(id)","delta":{"type":"output","text":"running…\n"}"#)
        pump(0.1)
        send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Bash","arg":"cargo test","input":{"command":"cargo test"},"outcome":"ok","output":"ok","display":null}"#)
    }

    /// The pill over a running turn for `seconds`, counting what its pieces built. Feeding is
    /// synchronous on the main actor, interleaved with the run loop by the run-step pump: no
    /// competing task, no unbounded loop.
    private func measure(_ variant: String) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-pill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = Workspace(folder: dir, fresh: true)
        defer { w.stop() }
        UserDefaults.standard.removeObject(forKey: "lastModel")
        UserDefaults.standard.set("ask", forKey: "newMessageModelPolicy")

        let c = Conversation(preview: dir)
        let view = ActivityViewer(workspace: w, conversation: c)
            .padding(40)
            .frame(width: 520, height: 120, alignment: .leading)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        // The turn starts before counting: the window is the pill in a steady running turn,
        // not the state change into one.
        send(c, #""turn_started","turn":1,"input":"Refactor the parser and run the tests""#)
        pump(1.0)
        PillProbe.reset()
        TranscriptProbe.reset()

        let started = Date()
        var spent = 0.0
        while spent < Self.seconds {
            runStep(into: c)
            spent = Date().timeIntervalSince(started)
        }
        let counted = spent

        let mins = counted / 60
        func pm(_ n: Int) -> Int { max(0, Int((Double(n) / mins).rounded())) }
        let total = PillProbe.viewerBodies + PillProbe.labelBodies + PillProbe.frogBodies + PillProbe.lineBodies
        print("pill: [\(variant)] \(String(format: "%.1f", counted))s window — \(pm(total)) total updates/min"
              + " (viewer \(pm(PillProbe.viewerBodies)), label \(pm(PillProbe.labelBodies)),"
              + " clock \(pm(PillProbe.clockTicks)), frog \(pm(PillProbe.frogBodies)), line \(pm(PillProbe.lineBodies)))")
    }

    /// Current build, frog on, sweep on: the churn suspect as shipped.
    func testBaseline() throws { try measure("baseline") }
}

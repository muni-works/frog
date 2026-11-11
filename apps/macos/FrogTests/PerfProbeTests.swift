import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Times the real transcript and composer views on synthetic events and prints `PROBE` lines
/// (docs/plans/mac-live-findings-2026-11-05.md). About a minute and a busy core, and nothing
/// asserted, so it's skipped unless asked for:
/// `TEST_RUNNER_FROG_PERF_PROBE=1 xcodebuild test ... -only-testing:FrogTests/PerfProbeTests`.
@MainActor
final class PerfProbeTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FROG_PERF_PROBE"] != nil, "perf probe: set FROG_PERF_PROBE=1")
    }

    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019
    private func send(_ c: Conversation, _ event: String) {
        seq += 1; clock += 7
        let line = #"{"seq":\#(seq),"session":"p","created":\#(clock),"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }
    private static func json(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s]); return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
    private static func answer(_ n: Int) -> String {
        "Turn \(n). Prose that wraps over a few lines in a narrow pane so the lazy stack estimates heights.\n\n- **offsets** stable\n- `Tail` carries bytes\n\n```swift\nfunc scan() {\n    for log in urls { watch(log) }\n}\n```\n\n```rust\nfn main() { println!(\"{}\", \(n)); }\n```\n\nDone \(n)."
    }
    private func mem() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return Double(info.phys_footprint) / 1_048_576
    }
    private func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
    private func pump(_ s: TimeInterval = 0.001) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func ms(_ f: () -> Void) -> Double { let t = Date(); f(); return Date().timeIntervalSince(t) * 1000 }
    private func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrolls) }
    private func turn(_ c: Conversation, _ t: Int, pumpEvery: Int = 0) {
        send(c, #""turn_started","turn":\#(t),"input":\#(Self.json("Do step \(t)"))"#)
        let tid = "tool-\(t)"
        send(c, #""item_started","id":"\#(tid)","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
        send(c, #""item_completed","id":"\#(tid)","item":{"type":"tool_call","name":"Bash","arg":"cargo test","input":{"command":"cargo test"},"outcome":"ok","output":"ok","display":null}"#)
        let id = "msg-\(t)"; let text = Self.answer(t)
        send(c, #""item_started","id":"\#(id)","kind":{"type":"message"}"#)
        var at = text.startIndex; var k = 0
        while at < text.endIndex {
            let nx = text.index(at, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            send(c, #""item_delta","id":"\#(id)","delta":{"type":"text","text":\#(Self.json(String(text[at..<nx])))}"#)
            at = nx; k += 1; if pumpEvery > 0, k % pumpEvery == 0 { pump(0.016) }
        }
        send(c, #""item_completed","id":"\#(id)","item":{"type":"message","text":\#(Self.json(text))}"#)
        send(c, #""turn_ended","turn":\#(t),"reason":{"type":"complete"},"usage":{"context_tokens":1,"input_tokens":1,"output_tokens":1,"model_calls":1,"tokens_per_sec":28.4}"#)
        send(c, #""idle""#)
    }

    func testLongTranscript() throws {
        for table in [false, true] {
            TranscriptContainer.table = table
            let was = TranscriptContainer.table
            defer { TranscriptContainer.table = was }
            print("PROBE container: \(table ? "table" : "lazy stack")")
            try longTranscript()
        }
    }

    private func longTranscript() throws {
        let m0 = mem()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "p")
        let view = TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }), jump: .constant(nil), onVisibleTurns: { _ in })
        let host = NSHostingView(rootView: view); host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil); defer { w.close() }
        pump(0.2); let mEmpty = mem()
        let ingest = ms { for t in 1...300 { turn(c, t) } }
        let firstLayout = ms { pump(0.001); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() }
        pump(0.5); let m300 = mem()
        // scroll: 60 jumps, per-jump layout+display time, and the frame after (work a jump defers)
        var sc: [Double] = [], after: [Double] = []
        let s = scrolls(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
        for i in 0..<60 {
            let doc = s.documentView!; let maxY = max(0, doc.frame.height - s.contentView.bounds.height)
            let y = i % 2 == 0 ? CGFloat(i) / 60 * maxY : maxY * CGFloat(60 - i) / 60
            sc.append(ms { s.contentView.scroll(to: NSPoint(x: 0, y: y)); s.reflectScrolledClipView(s.contentView); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() })
            after.append(ms { pump(0.001); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() })
            pump(0.005)
        }
        // smooth scroll: 200 small steps of 40pt from top
        var sm: [Double] = []
        s.contentView.scroll(to: .zero); pump(0.05)
        for i in 0..<200 { sm.append(ms { s.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i) * 40)); s.reflectScrolledClipView(s.contentView); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() }) }
        // resize
        var rs: [Double] = []
        for i in 0..<30 { rs.append(ms { w.setContentSize(NSSize(width: 500 + (i % 2) * 800 + i * 10, height: 500 + i * 10)); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() }) }
        // streaming at the tail of 300 turns: CPU over wall time, 60Hz pumping
        w.setContentSize(NSSize(width: 900, height: 760)); pump(0.2)
        s.contentView.scroll(to: NSPoint(x: 0, y: s.documentView!.frame.height)); pump(0.1)
        let c0 = cpu(), t0 = Date()
        for t in 301...305 { turn(c, t, pumpEvery: 1) }
        let wall = Date().timeIntervalSince(t0), used = cpu() - c0
        let mEnd = mem()
        func p(_ a: [Double]) -> String { let s = a.sorted(); return String(format: "p50 %.1f p95 %.1f max %.1f ms (>16.7ms: %d/%d)", s[s.count/2], s[Int(Double(s.count)*0.95)], s.last!, a.filter { $0 > 16.7 }.count, a.count) }
        print(String(format: "PROBE mem start %.0f MB, empty view %.0f MB, 300 turns %.0f MB, end %.0f MB", m0, mEmpty, m300, mEnd))
        print(String(format: "PROBE ingest 300 turns %.0f ms; first layout %.0f ms", ingest, firstLayout))
        print("PROBE jump-scroll " + p(sc)); print("PROBE jump next frame " + p(after)); print("PROBE smooth-scroll " + p(sm)); print("PROBE resize " + p(rs))
        print(String(format: "PROBE streaming 5 turns at tail: wall %.1fs cpu %.1fs (%.0f%% of a core)", wall, used, used / wall * 100))
    }

    func testStreamCost() throws {
        for table in [false, true] {
            TranscriptContainer.table = table
            let was = TranscriptContainer.table
            defer { TranscriptContainer.table = was }
            print("PROBE container: \(table ? "table" : "lazy stack")")
            try streamCost()
        }
    }

    private func streamCost() throws {
        for prior in [0, 300] {
            let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "p")
            let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }), jump: .constant(nil), onVisibleTurns: { _ in }))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil)
            if prior > 0 { for t in 1...prior { turn(c, t) } }
            pump(1.0)
            var c0 = cpu(); var t0 = Date(); pump(3.0)
            let idle = (cpu() - c0) / Date().timeIntervalSince(t0)
            c0 = cpu(); t0 = Date()
            for t in (prior+1)...(prior+3) { turn(c, t, pumpEvery: 1) }
            let st = (cpu() - c0) / Date().timeIntervalSince(t0)
            print(String(format: "PROBE prior %d turns: idle cpu %.0f%%, streaming cpu %.0f%%", prior, idle*100, st*100))
            w.close(); pump(0.2)
        }
    }

    /// For a profiler: 300 turns, then a long stream at the tail, bracketed by `PROBE stream-begin`
    /// / `PROBE stream-end` so `sample <pid>` can be pointed at just the streaming.
    func testStreamProfile() throws {
        // Each mode in the same run, alternating, so machine load hits both alike.
        var results: [String: [(cpu: Double, work: Double, turns: Int, rows: Int)]] = [:]
        for round in 0..<2 {
            for mode in ["before", "after", "no-ink"] {
                let live = mode != "before"
                Conversation.streamsLive = live
                InkReveal.off = mode == "no-ink"
                defer { Conversation.streamsLive = true; InkReveal.off = false }
                let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "p")
                let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }), jump: .constant(nil), onVisibleTurns: { _ in }))
                host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
                let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil)
                for t in 1...300 { turn(c, t) }
                pump(1.0)
                if round == 0, live { print("PROBE stream-begin"); fflush(stdout) }
                TranscriptProbe.reset()
                let c0 = cpu()
                var work = 0.0
                for t in (301 + round * 10)...(305 + round * 10) {
                    work += ms { turn(c, t, pumpEvery: 0); host.layoutSubtreeIfNeeded(); w.displayIfNeeded() }
                    _ = t
                }
                // Streamed delta by delta with a frame between each, as the app does at 30 Hz.
                let id = "live-\(round)"
                send(c, #""turn_started","turn":\#(900 + round),"input":"go""#)
                send(c, #""item_started","id":"\#(id)","kind":{"type":"message"}"#)
                let text = String(repeating: Self.answer(1) + "\n\n", count: 6)
                var at = text.startIndex
                while at < text.endIndex {
                    let nx = text.index(at, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
                    work += ms {
                        send(c, #""item_delta","id":"\#(id)","delta":{"type":"text","text":\#(Self.json(String(text[at..<nx])))}"#)
                        host.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                    }
                    at = nx; pump(0.016)
                }
                results[mode, default: []].append((cpu() - c0, work, TranscriptProbe.turnBodies, TranscriptProbe.rowBodies))
                w.close(); pump(0.2)
            }
        }
        print("PROBE stream-end")
        for (k, v) in results.sorted(by: { $0.key > $1.key }) {
            for r in v {
                print(String(format: "PROBE stream %@: cpu %.2fs, main-thread work %.0f ms, turn bodies %d, row bodies %d", k, r.cpu, r.work, r.turns, r.rows))
            }
        }
    }

    /// One long answer streamed at the tail of 300 turns, delta by delta with a frame between:
    /// CPU over wall time for the stream alone, bracketed by `PROBE live-begin` for `sample`.
    /// Once into each container.
    func testStreamLive() throws {
        for table in [false, true] {
            TranscriptContainer.table = table
            let was = TranscriptContainer.table
            defer { TranscriptContainer.table = was }
            try streamLive()
        }
        // What the ink costs, in the table (as under Reduce Motion: words just appear).
        let was = TranscriptContainer.table
        TranscriptContainer.table = true
        InkReveal.off = true
        defer { TranscriptContainer.table = was; InkReveal.off = false }
        try streamLive()
    }

    private func streamLive() throws {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "p")
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }), jump: .constant(nil), onVisibleTurns: { _ in }))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 760)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil); defer { w.close() }
        for t in 1...300 { turn(c, t) }
        pump(1.0)
        send(c, #""turn_started","turn":900,"input":"go""#)
        send(c, #""item_started","id":"live","kind":{"type":"message"}"#)
        let text = String(repeating: Self.answer(1) + "\n\n", count: 12)
        print("PROBE live-begin"); fflush(stdout)
        let c0 = cpu(), t0 = Date()
        var at = text.startIndex
        while at < text.endIndex {
            // About what the engine's 30 Hz batches carry at 40 tokens a second.
            let nx = text.index(at, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
            send(c, #""item_delta","id":"live","delta":{"type":"text","text":\#(Self.json(String(text[at..<nx])))}"#)
            at = nx; pump(1.0 / 30)
        }
        let used = cpu() - c0, wall = Date().timeIntervalSince(t0)
        print(String(format: "PROBE live stream (%@): %d chars, wall %.1fs cpu %.2fs (%.0f%% of a core)",
                     (TranscriptContainer.table ? "table" : "lazy stack") + (InkReveal.off ? ", no ink" : ""), text.count, wall, used, used / wall * 100))
    }

    private struct Box: View {
        @State var text: String
        @State var height: CGFloat = 22
        let controller: ComposerController
        var body: some View {
            ComposerTextView(text: $text, height: $height, controller: controller, onSubmit: {}, onEscape: { false })
                .frame(width: 700, height: 180)
        }
    }

    func testComposerHugePaste() throws {
        for mb in [0.1, 1.0, 5.0] {
            let controller = ComposerController()
            let host = NSHostingView(rootView: Box(text: "", controller: controller)); host.frame = CGRect(x: 0, y: 0, width: 700, height: 200)
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil); pump(0.2)
            let line = "let value = compute(input, with: options) // a line of pasted code\n"
            let big = String(repeating: line, count: Int(mb * 1_048_576) / line.utf8.count)
            let m0 = mem()
            let paste = ms { controller.insert(big); host.layoutSubtreeIfNeeded(); w.displayIfNeeded(); pump(0.001) }
            var keys: [Double] = []
            for _ in 0..<20 { keys.append(ms { controller.insert("x"); host.layoutSubtreeIfNeeded(); w.displayIfNeeded(); pump(0.001) }) }
            let s = keys.sorted()
            print(String(format: "PROBE composer %.1f MB: paste %.0f ms, keystroke p50 %.1f max %.1f ms, mem +%.0f MB", mb, paste, s[10], s.last!, mem() - m0))
            w.close(); pump(0.1)
        }
    }
}

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
    private static var slowObserver: CFRunLoopObserver?
    override func setUp() async throws {
        container = TranscriptContainer.table
        // DIAG: a slowed main thread, like a loaded VM's late frames.
        if Self.slowObserver == nil, let ms = ProcessInfo.processInfo.environment["FROG_SLOW_MS"].flatMap(Double.init), ms > 0 {
            let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue, true, 0) { _, _ in
                usleep(useconds_t(ms * 1000))
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            Self.slowObserver = o
        }
    }
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
    nonisolated(unsafe) static var pumps = 0
    nonisolated(unsafe) static var stage = ""
    private func pump(_ s: TimeInterval) { Self.pumps += 1; RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// DIAG: a background watchdog that writes the follow log to FROG_DIAG_DIR when the test stalls.
    private func startWatchdog() -> () -> Void {
        let dir = ProcessInfo.processInfo.environment["FROG_DIAG_DIR"]
        final class Flag: @unchecked Sendable { var done = false; let lock = NSLock() }
        let flag = Flag()
        DiagLog.reset()
        let started = Date()
        let t = Thread {
            var lastPumps = -1, sameFor = 0, dumps = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                flag.lock.lock(); let d = flag.done; flag.lock.unlock()
                if d { return }
                let p = Self.pumps
                if p == lastPumps { sameFor += 1 } else { sameFor = 0; lastPumps = p }
                let elapsed = Date().timeIntervalSince(started)
                if dumps < 4, sameFor >= 10 || elapsed > (ProcessInfo.processInfo.environment["FROG_DIAG_AFTER"].flatMap(Double.init) ?? 25) + Double(dumps * 10) {
                    dumps += 1
                    let text = "stall dump \(dumps): elapsed \(Int(elapsed)) s, pumps \(p), pump unchanged for \(sameFor) s, stage \(Self.stage)\n" + DiagLog.dump() + "\n"
                    print("DIAG WATCHDOG " + text.prefix(400))
                    if let dir {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        let name = "\(dir)/streaming-\(Int(started.timeIntervalSince1970))-\(dumps).txt"
                        try? text.write(toFile: name, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        t.start()
        return { flag.lock.lock(); flag.done = true; flag.lock.unlock() }
    }

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

    private func dumpState(_ why: String) {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let f0 = TranscriptProbe.follows, r0 = TranscriptProbe.rowBodies, t0 = TranscriptProbe.turnBodies
        pump(1)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e9
        print("DIAG FAIL \(why) cpu1s=\(String(format: "%.2f", cpu)) follows+=\(TranscriptProbe.follows - f0) rows+=\(TranscriptProbe.rowBodies - r0) turns+=\(TranscriptProbe.turnBodies - t0) mounted=\(TranscriptProbe.mountedKeys.sorted().suffix(6))")
        for w in NSApp.windows {
            print("DIAG WIN \(type(of: w)) visible=\(w.isVisible) alpha=\(w.alphaValue) frame=\(w.frame) content=\(w.contentView.map { String(describing: type(of: $0)).prefix(80) } ?? "nil") mine=\(w === window)")
        }
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
                                  onVisibleTurns: { [weak self] ids in
                                      print("DIAG vis from table=\(table) n=\(ids.count) t=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))")
                                      self?.visible = ids })
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderInForTest()
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
            print("DIAG jump set table=\(table) t=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))")
            jumpBox.id = target
            let jt0 = Date()
            let jok = wait() { self.visible.contains(target) }
            print("DIAG jump table=\(table) ok=\(jok) dt=\(String(format: "%.2f", Date().timeIntervalSince(jt0))) box=\(String(describing: jumpBox.id)) visibleIdx=\(self.visible.compactMap { v in c.turns.firstIndex { $0.id == v } }) clip=\(self.scrollView?.contentView.bounds ?? .zero) doc=\(self.scrollView?.documentView?.frame.height ?? -1)")
            XCTAssertTrue(jok,
                          "table \(table): the jumped-to turn is on screen")
            XCTAssertTrue(wait() { !self.atEnd() }, "table \(table): a jump stops following")
            window.close()
        }
    }

    func testStreamingShowsWordsAndFollows() {
        if ProcessInfo.processInfo.environment["FROG_DIAG_ALLOWANCE"] != nil { executionTimeAllowance = 60 }
        let stopWatchdog = startWatchdog()
        defer { stopWatchdog() }
        for table in [false, true] {
            Self.stage = "open table=\(table)"
            let c = open(table: table, turns: 30)
            send(c, #""turn_started","turn":99,"input":"go""#)
            send(c, #""item_started","id":"t99","kind":{"type":"tool_call","name":"Bash","arg":"ls"}"#)
            send(c, #""item_completed","id":"t99","item":{"type":"tool_call","name":"Bash","arg":"ls","input":{"command":"ls"},"outcome":"ok","output":"ok","display":null}"#)
            send(c, #""item_started","id":"live","kind":{"type":"message"}"#)
            Self.stage = "deltas table=\(table)"
            for i in 0..<12 {
                send(c, #""item_delta","id":"live","delta":{"type":"text","text":"word\#(i) "}"#)
                // Each delta drawn before the next is sent, so this is a stream and not one buffered
                // write: wait for the words so far rather than sleeping a guessed interval.
                let t0 = Date()
                let ok = wait(timeout: 5) { self.drawnText().contains("word\(i) ") }
                let mtv = self.views(self.host, MessageTextView.self)
                if !ok { self.dumpState("delta \(i) table=\(table)") }
                print("DIAG table=\(table) i=\(i) ok=\(ok) dt=\(String(format: "%.2f", Date().timeIntervalSince(t0))) atEnd=\(self.atEnd()) rows=\(mtv.count) follows=\(TranscriptProbe.follows) doc=\(Int(self.scrollView?.documentView?.frame.height ?? -1)) clipMaxY=\(Int(self.scrollView?.contentView.bounds.maxY ?? -1)) last=\(mtv.last.map { String($0.string.suffix(30)) } ?? "-")")
            }
            do {
                // DIAG: is the main thread idle once the words are in, or still updating?
                let f0 = TranscriptProbe.follows, r0 = TranscriptProbe.rowBodies, t0 = TranscriptProbe.turnBodies
                let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                pump(2)
                let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e9
                print("DIAG idle table=\(table) cpu2s=\(String(format: "%.2f", cpu)) follows+=\(TranscriptProbe.follows - f0) rows+=\(TranscriptProbe.rowBodies - r0) turns+=\(TranscriptProbe.turnBodies - t0)")
            }
            send(c, #""item_delta","id":"live","delta":{"type":"text","text":"\n\nlast-line"}"#)
            defer { print("DIAG counters table=\(table) parks=\(DiagLog.parks) declined=\(DiagLog.declined)"); DiagLog.parks = 0; DiagLog.declined = 0 }
            Self.stage = "final waits table=\(table)"
            XCTAssertTrue(wait() { self.drawnText().contains("last-line") },
                          "table \(table): the streamed words are drawn")
            XCTAssertTrue(wait() { self.atEnd() },
                          "table \(table): follows a short answer to the end")
            window.close()
        }
    }

    /// DIAG scratch: a closed window's table transcript, re-rendered after the static flips to
    /// the lazy stack. Does it spin?
    func testZZStaleClosedTranscriptFlipsContainer() {
        let c = open(table: true, turns: Int(ProcessInfo.processInfo.environment["FROG_STALE_TURNS"] ?? "200") ?? 200)
        window.close()
        pump(0.3)
        TranscriptContainer.table = false
        let mode = ProcessInfo.processInfo.environment["FROG_STALE_POKE"] ?? "event"
        var n = 0
        for _ in 0..<5 {
            n += 1
            if mode == "event" { turn(c, 1000 + n) } else { jumpBox.id = c.turns[3].id }
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let p0 = Self.pumps
            let start = Date()
            pump(1)
            print("DIAG stale poke \(n) cpu=\(String(format: "%.2f", Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e9)) wall=\(String(format: "%.2f", Date().timeIntervalSince(start))) stack=\(views(host, NSTableView.self).isEmpty) scrolls=\(views(host, NSScrollView.self).count)")
            _ = p0
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

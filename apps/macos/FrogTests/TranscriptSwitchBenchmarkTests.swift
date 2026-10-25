import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The switch benchmark, beside the streaming one (`TranscriptStreamBenchmarkTests`): open a
/// long session the way the sidebar does, and time it. A session is synthesized as the engine
/// replays it on `subscribe` (one JSON line per durable event, 40 rows a turn: answers between
/// tool calls, edits with diffs, and screenshots, whose base64 PNGs are most of a real log's
/// bytes), then:
///
///  - picked: the conversation is made, its history decoded line by line and delivered as the
///    engine's pipe would, up to `synced`, and the transcript mounted in place of the last one;
///  - first paint: the first rows are built and the window has displayed them;
///  - ready: scrolled to the end and still (at the bottom, over laid-out content, the document
///    height steady for a few frames), with ink in the visible area.
///
/// Asserts both against budgets, and how many rows were ever on screen at once
/// (`TranscriptProbe.peakMountedRows`): a virtualized transcript keeps that to the visible set.
///
///     xcodebuild test ... -only-testing:FrogTests/TranscriptSwitchBenchmarkTests
///
/// Prints `switch:` lines with the numbers.
@MainActor
final class TranscriptSwitchBenchmarkTests: XCTestCase {
    /// Budgets, debug build, with room for a loaded machine. Measured before the fixes (M-series,
    /// debug): 400 rows paint 235 ms, ready 259 ms (decode 43, fold 21, the rest the last turn's
    /// 40 rows built three times over, screenshots decoded in their bodies) — the "Loading
    /// session" Cam sees, before the engine's own replay (50–210 ms on his logs) is counted.
    /// 5,000 rows paint 3.1 s, ready 3.2 s: folding the history is quadratic (2.8 s, `upsert`
    /// copying every item it scans past), and once it took 23 s to settle at the end.
    private static let budget400 = (paint: 0.6, ready: 1.5)
    private static let budget5000 = (paint: 2.5, ready: 5.0)

    struct Opened {
        var decode: TimeInterval = 0
        var deliver: TimeInterval = 0
        var paint: TimeInterval = 0
        var ready: TimeInterval = 0
        var peakRows = 0
        var rowBodies = 0
        var ink: Double = 0
        var settled = false
        var bytes = 0
    }

    // MARK: The session

    /// A PNG of `side`×`side` noise, base64: a screenshot's weight in the log.
    private static func screenshot(side: Int) -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var rng = SystemRandomNumberGenerator()
        let bytes = rep.bitmapData!
        for i in 0..<(rep.bytesPerRow * side) { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// The engine's replay of a session with `rows` items, `perTurn` to a turn, a screenshot every
    /// `imageEvery` rows: one envelope line per event, as `subscribe` sends them.
    static func session(_ id: String, rows: Int, perTurn: Int = 40, imageEvery: Int, imageSide: Int = 480) -> [String] {
        var out: [String] = []
        var seq: UInt64 = 0
        var clock: Int64 = 1_790_113_417_019
        func send(_ event: String) {
            seq += 1
            clock += 700
            out.append(#"{"seq":\#(seq),"session":"\#(id)","created":\#(clock),"event":\#(event)}"#)
        }
        let png = screenshot(side: imageSide)
        send(#""titled","title":"switch bench""#)
        var turn: UInt64 = 0
        for r in 0..<rows {
            if r % perTurn == 0 {
                if turn > 0 {
                    send(#""turn_ended","turn":\#(turn),"reason":{"type":"complete"},"usage":{"context_tokens":2377,"input_tokens":13861,"output_tokens":470,"model_calls":20,"tokens_per_sec":28.4,"model":"local/qwen3-4b"}"#)
                }
                turn += 1
                send(#""turn_started","turn":\#(turn),"input":\#(json("Turn \(turn): refactor the next module and run the tests"))"#)
            }
            if imageEvery > 0, r % imageEvery == imageEvery - 1 {
                let id = "shot-\(r)"
                send(#""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Screenshot","arg":"http://localhost:5173"}"#)
                send(#""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Screenshot","arg":"http://localhost:5173","input":{"url":"http://localhost:5173"},"outcome":"ok","output":"captured","display":null,"images":[{"mime":"image/png","data":"\#(png)"}]}"#)
                continue
            }
            if r % 2 == 0 {
                let id = "msg-\(r)"
                let text = "Step \(r / 2): checked the parser against the fixtures and moved on to the next file. The **tokenizer** now keeps `spans` intact, and the tests pass."
                send(#""item_started","id":"\#(id)","kind":{"type":"message"}"#)
                send(#""item_completed","id":"\#(id)","item":{"type":"message","text":\#(json(text))}"#)
                continue
            }
            let id = "tool-\(r)"
            switch (r / 2) % 3 {
            case 0:
                let path = "src/file\(r / 12).swift"
                send(#""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Edit","arg":"\#(path)"}"#)
                send(#""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Edit","arg":"\#(path)","input":{"file_path":"\#(path)"},"outcome":"ok","output":"ok","display":null,"diff":{"path":"\#(path)","created":false,"added":3,"removed":1,"hunks":[{"lines":[{"kind":"add","old":null,"new":\#(r),"text":"let x = \#(r)"}]}]}}"#)
            case 1:
                send(#""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Read","arg":"src/read\#(r).swift"}"#)
                send(#""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Read","arg":"src/read\#(r).swift","input":{"file_path":"src/read\#(r).swift"},"outcome":"ok","output":"1 line","display":null}"#)
            default:
                send(#""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
                send(#""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Bash","arg":"cargo test","input":{"command":"cargo test"},"outcome":"ok","output":"ok\ntest result: ok. 12 passed","display":null}"#)
            }
        }
        send(#""turn_ended","turn":\#(turn),"reason":{"type":"complete"},"usage":{"context_tokens":2377,"input_tokens":13861,"output_tokens":470,"model_calls":20,"tokens_per_sec":28.4,"model":"local/qwen3-4b"}"#)
        return out
    }

    // MARK: The window

    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!

    override func setUp() async throws {
        host = NSHostingView(rootView: AnyView(Color.clear.frame(width: 900, height: 700)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        host = nil
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Open `lines` as the sidebar does: replay, then the transcript takes the window.
    func open(_ lines: [String], session: String) throws -> (Opened, Conversation) {
        var m = Opened()
        m.bytes = lines.reduce(0) { $0 + $1.utf8.count }
        TranscriptProbe.reset()
        let link = ReplayLink()
        let picked = Date()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: true, session: session)
        // The engine's pipe: each line decoded (off the main thread in the app, but it's the
        // same work and it's on the way to the first paint), then delivered.
        var envs: [Envelope] = []
        envs.reserveCapacity(lines.count)
        let decoder = JSONDecoder.frog
        for line in lines {
            envs.append(try decoder.decode(Envelope.self, from: Data(line.utf8)))
        }
        m.decode = Date().timeIntervalSince(picked)
        var t = Date()
        for env in envs { link.onEvent(env) }
        let upto = envs.last?.seq ?? 0
        link.onEvent(try decoder.decode(Envelope.self, from: Data(#"{"seq":\#(upto + 1),"session":"\#(session)","created":0,"event":"synced","upto":\#(upto)}"#.utf8)))
        m.deliver = Date().timeIntervalSince(t)
        XCTAssertFalse(c.replaying)

        t = Date()
        host.rootView = AnyView(
            TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
                .id(ObjectIdentifier(c))
                .frame(width: 900, height: 700))
        // First paint: rows built and displayed.
        while TranscriptProbe.rowBodies == 0, Date().timeIntervalSince(t) < 20 { pump(0.001) }
        host.displayIfNeeded()
        m.paint = Date().timeIntervalSince(picked)

        // Ready: at the end, over content, the document steady for three frames.
        let scroll = try XCTUnwrap(TranscriptBench.outerScroll(in: host), "no scroll view")
        var steady = 0, lastHeight: CGFloat = -1
        while Date().timeIntervalSince(t) < 10 {
            pump(0.005)
            let height = scroll.documentView?.bounds.height ?? 0
            let ok = TranscriptBench.below(scroll) < 24 && TranscriptBench.overContent(scroll) && height == lastHeight
            lastHeight = height
            steady = ok ? steady + 1 : 0
            if steady >= 3 { m.settled = true; break }
        }
        m.ready = Date().timeIntervalSince(picked) - 0.015
        m.ink = TranscriptBench.ink(scroll, in: host)
        m.peakRows = TranscriptProbe.peakMountedRows
        m.rowBodies = TranscriptProbe.rowBodies
        return (m, c)
    }

    private func report(_ name: String, rows: Int, _ m: Opened) {
        print("switch: \(name) \(rows) rows, \(m.bytes / 1024) KB log: paint \(Int(m.paint * 1000)) ms, ready \(Int(m.ready * 1000)) ms (decode \(Int(m.decode * 1000)) ms, deliver \(Int(m.deliver * 1000)) ms)")
        print("switch: \(name) peak mounted rows \(m.peakRows), row bodies \(m.rowBodies), ink \(String(format: "%.4f", m.ink)), settled \(m.settled)")
    }

    private func check(_ m: Opened, _ budget: (paint: Double, ready: Double), _ name: String) {
        XCTAssertTrue(m.settled, "\(name): never settled at the end")
        XCTAssertGreaterThan(m.ink, 0.002, "\(name): blank once ready")
        XCTAssertLessThan(m.paint, budget.paint, "\(name): first paint over budget")
        XCTAssertLessThan(m.ready, budget.ready, "\(name): ready over budget")
    }

    func testSwitchTo400RowSession() throws {
        // Warm up SwiftUI and the decoder so the first measured open isn't paying for them.
        _ = try open(Self.session("warm", rows: 40, imageEvery: 9), session: "warm")
        // 400 rows, a screenshot every 6th (Cam's 8a50: 218 items, 72 screenshots, 56 MB).
        let lines = Self.session("s400", rows: 400, imageEvery: 6)
        let (m, c) = try open(lines, session: "s400")
        report("s400", rows: 400, m)
        XCTAssertEqual(c.turns.reduce(0) { $0 + $1.items.count }, 400)
        check(m, Self.budget400, "s400")
    }

    func testSwitchTo5000RowSession() throws {
        _ = try open(Self.session("warm", rows: 40, imageEvery: 9), session: "warm")
        // 5,000 rows, few screenshots (Cam's 3288: 4,243 items, 873 turns, 23 MB).
        let lines = Self.session("s5000", rows: 5000, imageEvery: 200)
        let (m, c) = try open(lines, session: "s5000")
        report("s5000", rows: 5000, m)
        XCTAssertEqual(c.turns.reduce(0) { $0 + $1.items.count }, 5000)
        XCTExpectFailure("baseline: folding a 5,000-row history is quadratic", strict: false)
        check(m, Self.budget5000, "s5000")
    }
}

/// A link that only carries what the test delivers (the engine's replay), and takes any op.
@MainActor
final class ReplayLink: ConversationLink {
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var ops: [Op] = []
    func send(_ op: Op) { ops.append(op) }
    func stop() {}
    var endDescription: String { "" }
}

/// Window probes shared by the transcript benchmarks.
@MainActor
enum TranscriptBench {
    static func outerScroll(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = outerScroll(in: sub) { return s } }
        return nil
    }

    /// Content below the visible rect, in points (the transcript's own measure of "at bottom").
    static func below(_ scroll: NSScrollView) -> CGFloat {
        guard let doc = scroll.documentView else { return 0 }
        let visible = scroll.documentVisibleRect
        let inset = scroll.contentInsets.bottom
        return doc.isFlipped ? doc.bounds.height - (visible.maxY - inset) : visible.minY + inset
    }

    /// The visible rect lies over laid-out content (not past either end of the document).
    static func overContent(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return false }
        let overlap = scroll.documentVisibleRect.intersection(doc.bounds)
        return overlap.height >= min(doc.bounds.height, scroll.documentVisibleRect.height) * 0.5
    }

    /// The fraction of the visible area with ink, by alpha (see the streaming benchmark).
    static func ink(_ scroll: NSScrollView, in host: NSView, stride step: Int = 4) -> Double {
        var rect = scroll.convert(scroll.bounds, to: host)
        rect = rect.insetBy(dx: 0, dy: 70)
        guard rect.height > 20, let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return 0 }
        host.cacheDisplay(in: rect, to: rep)
        var inked = 0, samples = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                if c.alphaComponent > 0.5 { inked += 1 }
            }
        }
        guard samples > 0 else { return 0 }
        return Double(inked) / Double(samples)
    }
}


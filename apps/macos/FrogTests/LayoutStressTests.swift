import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import Frog

/// A busy conversation, faster than real time, through the real transcript: streamed answers with
/// code blocks, tool calls, turns piling up, while the view scrolls and the window resizes (splits).
/// It hunts the AttributeGraph corruption behind docs/design/attributegraph-corruption.md, so it's
/// most useful under a sanitizer:
///
///     TEST_RUNNER_FROG_STRESS_SECONDS=300 xcodebuild test ... -only-testing:FrogTests/LayoutStressTests \
///         -enableAddressSanitizer YES
///
/// Passing means the graph survived the run; a corruption shows up as a crash in AttributeGraph.
@MainActor
final class LayoutStressTests: XCTestCase {
    /// Two panes on one conversation, each with the rail the transcript reports visible turns to.
    @Observable
    final class PaneState {
        var visible: Set<TurnState.ID> = []
        var jump: TurnState.ID?
    }

    private struct Panes: View {
        let conversation: Conversation
        let left: PaneState
        let right: PaneState

        var body: some View {
            HStack(spacing: 0) {
                pane(left)
                pane(right)
            }
        }

        private func pane(_ ui: PaneState) -> some View {
            let actions = TurnActions(fork: { _ in }, rewind: { _ in })
            return TranscriptView(conversation: conversation, actions: actions,
                                  jump: Bindable(ui).jump, onVisibleTurns: { ids in
                                      // As PaneView does: after the update, only on change.
                                      let visible = Set(ids)
                                      DispatchQueue.main.async { if ui.visible != visible { ui.visible = visible } }
                                  })
                .overlay(alignment: .trailing) {
                    TimelineRail(conversation: conversation, visible: ui.visible, actions: actions,
                                 jump: { ui.jump = $0 })
                        .frame(height: min(400, CGFloat(conversation.turns.count) * 22 + 28))
                }
        }
    }

    private var seq: UInt64 = 0
    private var clock: Int64 = 1_790_113_417_019

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        clock += 7
        let line = #"{"seq":\#(seq),"session":"stress","created":\#(clock),"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// An answer worth laying out: prose, a list, and code blocks (each one a hosting view in the
    /// text, see `MessageTextView`).
    private static func answer(_ n: Int) -> String {
        """
        Turn \(n). Here's what changed and why, with enough prose to wrap over a few lines in a \
        narrow pane and keep the lazy stack estimating heights it hasn't measured yet.

        - first, the parser now keeps **offsets** stable
        - then the `Tail` struct carries pending bytes
        - finally the watcher reads on its own queue

        ```swift
        func scan() {
            for log in urls where log.pathExtension == "jsonl" {
                if files[log.lastPathComponent] == nil { watch(log) }
            }
        }
        ```

        And a second block, so blocks after the first difference get rebuilt while streaming:

        ```rust
        fn main() {
            let a = \(n);
            println!("{}", a + 1);
        }
        ```

        Done with turn \(n).
        """
    }

    private func host(_ view: some View, size: CGSize) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }

    /// Lets AppKit and SwiftUI run a frame: layout, display, geometry callbacks, async work.
    private func pump(_ seconds: TimeInterval = 0.001) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// SwiftUI's own complaints about this process's layout (feedback loops between a geometry
    /// callback and the layout it reads), by message.
    static func swiftUIWarnings(since: Date) throws -> [String: Int] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var out: [String: Int] = [:]
        for case let e as OSLogEntryLog in try store.getEntries(at: store.position(date: since))
        where e.subsystem == "com.apple.SwiftUI" || e.composedMessage.contains("[Invalid Configuration]")
            || e.category == "Invalid Configuration" {
            out[e.composedMessage, default: 0] += 1
        }
        return out
    }

    func testStreamingWhileScrollingAndResizing() throws {
        let started = Date()
        // Streaming only, no scrolling or resizing from here: what the app does on its own.
        let passive = ProcessInfo.processInfo.environment["FROG_STRESS_PASSIVE"] != nil
        let seconds = Double(ProcessInfo.processInfo.environment["FROG_STRESS_SECONDS"] ?? "") ?? 8
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "stress")
        let left = PaneState(), right = PaneState()
        let (window, host) = host(Panes(conversation: c, left: left, right: right), size: CGSize(width: 1100, height: 760))
        defer { window.close() }
        var rng = SystemRandomNumberGenerator()
        let end = Date().addingTimeInterval(seconds)
        var turn: UInt64 = 0
        var events = 0
        while Date() < end {
            turn += 1
            send(c, #""turn_started","turn":\#(turn),"input":\#(Self.json("Do step \(turn), and explain it"))"#)
            send(c, #""progress","label":"thinking""#)
            // A couple of tool calls, one with live output.
            for t in 0..<2 {
                let id = "tool-\(turn)-\(t)"
                send(c, #""item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
                for k in 0..<5 { send(c, #""item_delta","id":"\#(id)","delta":{"type":"output","text":"line \#(k)\n"}"#) }
                send(c, #""item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Bash","arg":"cargo test","input":{"command":"cargo test"},"outcome":"ok","output":"ok","display":null}"#)
                pump()
            }
            let id = "msg-\(turn)"
            send(c, #""item_started","id":"\#(id)","kind":{"type":"message"}"#)
            let text = Self.answer(Int(turn))
            var at = text.startIndex
            while at < text.endIndex {
                let step = Int.random(in: 2...9, using: &rng)
                let next = text.index(at, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
                send(c, #""item_delta","id":"\#(id)","delta":{"type":"text","text":\#(Self.json(String(text[at..<next])))}"#)
                at = next
                events += 1
                if events % 3 == 0 { pump() }
                // Your own scrolling, mid-stream: somewhere random, or back to the end.
                if !passive, events % 17 == 0, let scroll = scrollViews(in: host).randomElement(using: &rng),
                   let doc = scroll.documentView {
                    let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
                    let y = Bool.random(using: &rng) ? maxY : CGFloat.random(in: 0...max(1, maxY), using: &rng)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                // A split opening, closing, or being dragged.
                if !passive, events % 41 == 0 {
                    let w = CGFloat.random(in: 600...1400, using: &rng), h = CGFloat.random(in: 420...900, using: &rng)
                    window.setContentSize(NSSize(width: w, height: h))
                }
                // The rail jumping to a turn.
                if !passive, events % 97 == 0, let t = c.turns.randomElement(using: &rng) { left.jump = t.id }
            }
            send(c, #""item_completed","id":"\#(id)","item":{"type":"message","text":\#(Self.json(text))}"#)
            send(c, #""turn_ended","turn":\#(turn),"reason":{"type":"complete"},"usage":{"context_tokens":2377,"input_tokens":13861,"output_tokens":470,"model_calls":3,"tokens_per_sec":28.4}"#)
            send(c, #""idle""#)
            pump(0.01)
        }
        pump(0.3)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(c.turns.count, Int(turn))
        print("stress: \(turn) turns, \(seq) events in \(seconds)s")
        let warnings = try Self.swiftUIWarnings(since: started)
        for (message, n) in warnings.sorted(by: { $0.value > $1.value }) { print("stress: swiftui \(n)× \(message)") }
    }
}

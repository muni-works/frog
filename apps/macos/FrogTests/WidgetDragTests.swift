import AppKit
import ObjectiveC
import SwiftUI
import WebKit
import XCTest
@testable import Frog

/// A drag that starts inside a visual (`WidgetCard`) is the visual's: its slider moves and the
/// window doesn't. The window root drags the window from any empty space (`WindowDragGesture`,
/// `RootView`), and SwiftUI hands the events AppKit sends the visual's web view to the gestures
/// around it too, so dragging a slider in a visual moved the window.
///
/// A synthetic drag doesn't start a real window drag in a test (`WindowDragFallThroughTests`),
/// so the root here carries a counting `DragGesture` where the app has `WindowDragGesture`: an
/// ancestor gesture either way, reached (or not) the same way.
@MainActor
final class WidgetDragTests: XCTestCase {
    /// CI (`TestRunner.isCI`): skipped, like the other display-driven tests. They run locally
    /// through `apps/macos/scripts/test.sh`.
    override func setUpWithError() throws {
        try XCTSkipIf(TestRunner.isCI, "posts synthetic mouse drags at a window, which a CI runner's virtual display doesn't deliver")
    }

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    private final class Count { var n = 0 }

    /// The test host is an inactive app, where AppKit holds a press back from a view that won't
    /// take the first mouse (a web view doesn't); in the app the window is key. For this test
    /// the visual's web view takes it.
    private func acceptFirstMouse() -> () -> Void {
        let sel = #selector(NSView.acceptsFirstMouse(for:))
        let yes: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        class_addMethod(WidgetWKWebView.self, sel, imp_implementationWithBlock(yes), "c@:@")
        return {
            if let m = class_getInstanceMethod(WKWebView.self, sel) {
                class_replaceMethod(WidgetWKWebView.self, sel, method_getImplementation(m), method_getTypeEncoding(m))
            }
        }
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    /// A slider along the top of the page, at 0, that reports the page's height (so the card
    /// shows it).
    private let html = """
    <!doctype html><html><body style="margin:0;height:300px">
    <input id="r" type="range" min="0" max="100" value="0" style="position:absolute;left:20px;top:20px;width:400px;margin:0">
    <script>window.webkit.messageHandlers.frog.postMessage(JSON.stringify({frogWidget:1,type:"height",height:300}))</script>
    </body></html>
    """

    func testSliderDragStaysInVisual() async throws {
        let restore = acceptFirstMouse()
        defer { restore() }
        let folder = URL(fileURLWithPath: "/tmp/demo")
        let conversation = Conversation(folder: folder, link: nil, replay: false, session: "demo")
        let widget = VisualWidget(title: "Sampling temperature", code: "", html: html)
        let rootDrags = Count()
        let root = VStack(spacing: 0) {
            Color.clear.frame(height: 100)
            WidgetCard(widget: widget, conversation: conversation).frame(width: 600)
            Color.clear
        }
        .frame(width: 800, height: 600)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 3).onChanged { _ in rootDrags.n += 1 })
        .allowsWindowActivationEvents(true)
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        // Laid out and drawing, never seen: far off the desktop, transparent, and the app isn't
        // activated.
        w.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        w.alphaValue = 0
        w.animationBehavior = .none
        w.collectionBehavior.formUnion([.transient, .ignoresCycle])
        w.orderFrontRegardless()
        defer { w.close() }
        pump(1.0)
        let web = try XCTUnwrap(find(WidgetWKWebView.self, in: w.contentView!), "no web view")
        var loaded = false
        for _ in 0..<50 where !loaded {
            loaded = (try? await web.evaluateJavaScript("document.getElementById('r') != null") as? Bool) == true
            pump(0.1)
        }
        XCTAssertTrue(loaded, "the visual never loaded")
        pump(0.5) // the "Drawing…" cover goes once the page reports its height

        /// A press at `at` (window coordinates), a drag of 200 points right in steps, a release.
        func drag(at p: CGPoint) {
            func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.sendEvent(event(.leftMouseDown, p.x))
            pump(0.1)
            for i in 1...10 {
                NSApp.sendEvent(event(.leftMouseDragged, p.x + 20 * CGFloat(i)))
                pump(0.05)
            }
            NSApp.sendEvent(event(.leftMouseUp, p.x + 200))
            pump(0.5)
        }

        // The rig reaches the root: a drag on empty space is the root's.
        drag(at: CGPoint(x: 20, y: 20))
        XCTAssertGreaterThan(rootDrags.n, 0, "a drag on empty space never reached the root's gesture")

        // The slider's thumb, at the page's top left: the slider takes it, the root doesn't.
        rootDrags.n = 0
        let f = web.convert(web.bounds, to: nil)
        XCTAssertEqual(w.contentView!.hitTest(CGPoint(x: f.minX + 28, y: f.maxY - 28)), web, "the press doesn't land on the web view")
        drag(at: CGPoint(x: f.minX + 28, y: f.maxY - 28))
        let value = try await web.evaluateJavaScript("document.getElementById('r').value") as? String
        XCTAssertGreaterThan(Int(value ?? "") ?? 0, 20, "the slider didn't take the drag")
        XCTAssertEqual(rootDrags.n, 0, "a drag on the visual's slider reached the window root's gesture (which moves the window)")
    }
}

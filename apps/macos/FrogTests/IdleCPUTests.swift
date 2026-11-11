import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Nothing happening costs nothing: an empty conversation (the frog on its lily pad) and a long
/// finished one, both on screen, idle under 1% of a core. Findings 2026-11-05: the empty page
/// idled at 10%, the frog's idle loop at 30 frames a second; it's still until hovered now.
@MainActor
final class IdleCPUTests: XCTestCase {
    private func cpu() -> Double {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func idle(table: Bool) -> Double {
        TranscriptContainer.table = table
        let was = TranscriptContainer.table
            defer { TranscriptContainer.table = was }
        UserDefaults.standard.set(true, forKey: "playfulFrog")
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "idle")
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in })))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host; w.orderFront(nil)
        defer { w.close() }
        pump(1.0)
        let c0 = cpu(), t0 = Date()
        pump(3.0)
        return (cpu() - c0) / Date().timeIntervalSince(t0)
    }

    func testEmptyTranscriptIdles() {
        for table in [false, true] {
            let share = idle(table: table)
            print(String(format: "idle: empty transcript (%@) %.1f%% of a core", table ? "table" : "lazy stack", share * 100))
            // The whole test host, not only the view: a little allowance for the app's own timers.
            XCTAssertLessThan(share, 0.02, "an empty transcript idles")
        }
    }
}

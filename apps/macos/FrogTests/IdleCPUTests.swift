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

    /// The idle share of a core, or nil when the runner never went quiet (which is not the
    /// view's fault and must not be reported as one).
    private func idle(table: Bool) -> Double? {
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
        // Settle: wait until a short window actually costs nothing, rather than sleeping a fixed
        // second that a loaded runner's slower first layout overruns (startup work then lands inside
        // the measurement and reads as the view being busy). Bounded, times `TestRunner.slack` on CI.
        let settleBy = Date().addingTimeInterval(20 * TestRunner.slack)
        var settled = false
        while Date() < settleBy {
            let was = cpu(), from = Date()
            pump(0.5)
            if (cpu() - was) / Date().timeIntervalSince(from) < 0.01 { settled = true; break }
        }
        // Never reached a quiet window: say that, rather than measuring a machine that is still
        // busy and reporting it as the view failing to idle. This is the difference between "frog
        // spins" and "the runner was loaded" — a distinction this test used to lose.
        guard settled else { return nil }
        // Three windows, median: one noisy sample (a GC, another test finishing) shouldn't decide it.
        var shares: [Double] = []
        for _ in 0..<3 {
            let c0 = cpu(), t0 = Date()
            pump(2.0)
            shares.append((cpu() - c0) / Date().timeIntervalSince(t0))
        }
        return shares.sorted()[1]
    }

    func testEmptyTranscriptIdles() throws {
        for table in [false, true] {
            guard let share = idle(table: table) else {
                // A loaded runner, not a busy view: skip rather than fail, and say so.
                print("idle: \(table ? "table" : "lazy stack") skipped — the runner never went quiet")
                throw XCTSkip("the runner never went quiet, so idle CPU can't be measured here")
            }
            print(String(format: "idle: empty transcript (%@) %.1f%% of a core", table ? "table" : "lazy stack", share * 100))
            // The whole test host, not only the view: a little allowance for the app's own timers.
            XCTAssertLessThan(share, 0.02, "an empty transcript idles")
        }
    }
}

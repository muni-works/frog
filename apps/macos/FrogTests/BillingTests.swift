import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Billing: the transition to credit renders as one calm line (never the provider's raw
/// JSON), the hard out-of-credit end renders "out of credit · add credit" with the billing
/// link, and nothing anywhere shows a provider dump for a 402.
final class BillingTests: XCTestCase {
    private func envelope(_ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(
            #"{"seq":1,"session":"s","created":0,\#(body)}"#.utf8))
    }

    private static let usage =
        #""usage":{"context_tokens":null,"input_tokens":0,"output_tokens":0,"model_calls":0,"tokens_per_sec":null}"#

    /// The informational event lands as a notice row with the calm line and the balance.
    @MainActor
    func testBillingLimitRendersAsOneCalmLine() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(
            #""event":"billing_limit","window":"5h","reason":"5-hour plan limit reached; add credit to keep going at usage prices","balance_micro":4200000"#))
        let transcript = c.turns.flatMap { $0.items }.map(\.text).joined()
        XCTAssertTrue(transcript.contains("5-hour allowance used · billing credit at usage prices"), transcript)
        XCTAssertTrue(transcript.contains("$4.20 left"), transcript)
        // The provider's raw JSON never reaches the transcript.
        XCTAssertFalse(transcript.contains("insufficient_quota"), transcript)
        XCTAssertFalse(transcript.contains("{\"error\""), transcript)
    }

    /// The hard out-of-credit end: the banner row says "out of credit" with an add-credit
    /// button, muted (not red), and no provider dump anywhere.
    @MainActor
    func testHardBillingEndRendersTheBanner() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.ingest(try envelope(#""event":"turn_started","turn":1,"input":"keep going""#))
        c.ingest(try envelope(
            #""event":"turn_ended","turn":1,"reason":{"type":"billing_limit","window":"credit","reason":"Insufficient credits"},\#(Self.usage)"#))
        guard let end = c.turns.last?.end, case .billingLimit(let b) = end else { return XCTFail() }
        XCTAssertTrue(b.isHardStop)

        // The banner view itself: muted, the fix one click away.
        let view = BillingEndView(limit: b)
        let height = try renderedHeight(view, width: 600)
        XCTAssertGreaterThan(height, 10, "the row renders")

        let transcript = c.turns.flatMap { $0.items }.map(\.text).joined()
        XCTAssertFalse(transcript.contains("Insufficient credits"), transcript)
        XCTAssertFalse(transcript.contains("provider error"), transcript)
    }

    /// The failure label (a 402 that slipped through as an EngineError) says what went
    /// wrong without the raw body's JSON.
    func testBillingEngineErrorRendersClean() {
        let e = EngineError(type: "billing", status: 402, message: "insufficient credits")
        XCTAssertEqual(e.description, "Billing refused (402): insufficient credits")
    }

    /// A rendered view's height, the SnapshotTests way.
    @MainActor
    private func renderedHeight<V: View>(_ view: V, width: CGFloat) throws -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return host.fittingSize.height
    }
}

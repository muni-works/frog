import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The opacity rule is about what a *view* draws, not what a helper returns: `displayName` can be
/// perfect while `EndView` still prints `servedBy.name` (Cam, 2026-11-12). These render the real
/// footer and compare pixels, so a revert to the leak goes red — the string "Cloudflare Workers AI"
/// is a different width and different glyphs from "Frog Cloud".
///
/// Text is not extractable from a SwiftUI hierarchy (no AX tree without TCC, no text in the PDF),
/// so the assertion is instead the one that matters: the footer must look the same whoever served
/// the turn. Written to fail without the fix; see the PR body for the red proof.
@MainActor
final class OpacityViewTests: XCTestCase {
    private func usage(_ served: ServedBy) -> TurnUsage {
        TurnUsage(contextTokens: nil, inputTokens: 900, outputTokens: 40, modelCalls: 2,
                  tokensPerSec: 24, model: "cloud/qwen3-coder-next", servedBy: served)
    }

    /// The bytes of a view drawn into a bitmap at a fixed size.
    private func pixels<V: View>(_ view: V, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func footer(_ served: ServedBy) -> some View {
        EndView(reason: .complete, usage: usage(served), answer: "", hovering: false)
            .padding(12)
            .frame(width: 460, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The leak this exists for: a third party upstream frog knows by name.
    func testAThirdPartyTurnDrawsIdenticallyToFrogClouds() throws {
        let frog = try pixels(footer(ServedBy(id: "frog", name: "Frog Cloud", thirdParty: false)),
                              size: CGSize(width: 460, height: 40))
        let upstream = try pixels(footer(ServedBy(id: "workers-ai", name: "Cloudflare Workers AI", thirdParty: true)),
                                  size: CGSize(width: 460, height: 40))
        // Rendering `servedBy.name` would make these differ: the upstream's name is longer, and the
        // glyphs are not the label's. Identical pixels mean the footer never drew it.
        XCTAssertEqual(frog, upstream, "the footer draws who served the turn: the upstream reached the view")
    }

    /// An upstream frog has never heard of, named however the gateway likes.
    func testAnUnknownUpstreamDrawsIdenticallyToo() throws {
        let frog = try pixels(footer(ServedBy(id: "frog", name: "Frog Cloud", thirdParty: false)),
                              size: CGSize(width: 460, height: 40))
        let acme = try pixels(footer(ServedBy(id: "acme", name: "Acme Inference Ltd.", thirdParty: true)),
                              size: CGSize(width: 460, height: 40))
        XCTAssertEqual(frog, acme, "the footer drew an unknown upstream's name")
    }

    /// The row does render something there: without this, a footer that drew no label at all would
    /// pass both tests above.
    func testTheFooterStillNamesFrogCloud() throws {
        let withServed = try pixels(footer(ServedBy(id: "frog", name: "Frog Cloud", thirdParty: false)),
                                    size: CGSize(width: 460, height: 40))
        let without = try pixels(
            EndView(reason: .complete, usage: usage2(), answer: "", hovering: false)
                .padding(12).frame(width: 460, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 460, height: 40))
        XCTAssertNotEqual(withServed, without, "no served-by label is drawn at all")
    }

    private func usage2() -> TurnUsage {
        TurnUsage(contextTokens: nil, inputTokens: 900, outputTokens: 40, modelCalls: 2,
                  tokensPerSec: 24, model: "cloud/qwen3-coder-next", servedBy: nil)
    }
}

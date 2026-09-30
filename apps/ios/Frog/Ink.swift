import SwiftUI

/// An answer that writes itself, like the Mac's `InkReveal`: words appear at a reading pace on
/// the display's clock rather than the network's, and each one inks in, starting in frog green
/// and settling into its own color. What has arrived but isn't revealed yet is laid out and
/// drawn clear, so the bubble never reflows under the words. Under Reduce Motion, text simply
/// appears.
struct InkMessage: View {
    let text: String
    /// Still arriving from the model.
    let streaming: Bool
    @State private var pen = InkPen()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || pen.settled {
            MessageBody(text: text)
        } else {
            TimelineView(.animation) { ctx in
                let now = ctx.date.timeIntervalSinceReferenceDate
                let rendered = pen.render(text)
                let shown = pen.advance(now: now, total: rendered.count, streaming: streaming)
                MessageBody(rendered: rendered, ink: pen.ink(revealed: shown, now: now))
                    .onChange(of: pen.caughtUp(streaming: streaming, total: rendered.count)) { _, done in
                        if done { pen.settle() }
                    }
            }
        }
    }
}

/// Where the pen is. Advanced every frame from inside the view, so per-frame fields aren't
/// observed; only `settled` is, to stop the clock once the text is all in.
@MainActor
@Observable
final class InkPen {
    private(set) var settled = false
    @ObservationIgnored private var revealed = 0.0
    @ObservationIgnored private var last: Double?
    /// When each stretch of characters appeared: (end offset, time).
    @ObservationIgnored private var stamps: [(end: Int, at: Double)] = []
    @ObservationIgnored private var cache: (text: String, rendered: RenderedMessage)?

    static let inkTime = 0.42
    static let lagStreaming = 0.32
    static let lagDone = 0.1
    /// About reading speed, in characters a second.
    static let minRate = 42.0

    func render(_ text: String) -> RenderedMessage {
        if let cache, cache.text == text { return cache.rendered }
        let r = RenderedMessage(text)
        cache = (text, r)
        return r
    }

    /// Move the pen for this frame; returns how many characters show.
    func advance(now: Double, total: Int, streaming: Bool) -> Int {
        let dt = min(0.05, now - (last ?? now))
        last = now
        let backlog = Double(total) - revealed
        guard backlog > 0 else { return total }
        let rate = max(Self.minRate, backlog / (streaming ? Self.lagStreaming : Self.lagDone))
        let before = Int(revealed)
        revealed = min(Double(total), revealed + rate * dt)
        let after = Int(revealed)
        if after > before { stamps.append((after, now)) }
        // Only the recent stamps matter; older text is fully inked.
        if let cut = stamps.firstIndex(where: { now - $0.at < Self.inkTime }), cut > 0 { stamps.removeFirst(cut - 1) }
        return after
    }

    /// The ink for this frame: the stretches still drying, and where the text stops showing.
    func ink(revealed: Int, now: Double) -> Ink {
        var runs: [(Range<Int>, Double)] = []
        var start = 0
        for s in stamps {
            let lo = min(start, revealed), hi = min(s.end, revealed)
            if hi > lo, now - s.at < Self.inkTime { runs.append((lo..<hi, (now - s.at) / Self.inkTime)) }
            start = s.end
        }
        return Ink(revealed: revealed, drying: runs)
    }

    func caughtUp(streaming: Bool, total: Int) -> Bool {
        !streaming && Int(revealed) >= total && stamps.allSatisfy { ($0.at + Self.inkTime) < (last ?? 0) }
    }

    func settle() {
        Task { self.settled = true }
    }
}

/// How far the ink has got, for `MessageBody`: character ranges over the rendered text.
struct Ink {
    let revealed: Int
    /// Recently written stretches and how dry they are (0 fresh … 1 dry).
    let drying: [(Range<Int>, Double)]

    /// Frog green, fading into the text's own color. Four steps are enough for the eye.
    static func color(_ t: Double) -> Color {
        Color.frog.mix(with: .primary, by: (t * 4).rounded(.down) / 4)
    }
}

/// A message split into prose and code, rendered once, with a character count to ink over.
struct RenderedMessage {
    enum Piece {
        case prose(AttributedString)
        case code(String)

        var count: Int {
            switch self {
            case .prose(let a): a.characters.count
            case .code(let s): s.count
            }
        }
    }

    let pieces: [Piece]
    let count: Int

    init(_ text: String) {
        pieces = MessageBody.pieces(text).map { p in
            switch p {
            case .prose(let s): .prose(MessageBody.inline(s))
            case .code(let s): .code(s)
            }
        }
        count = pieces.reduce(0) { $0 + $1.count }
    }
}

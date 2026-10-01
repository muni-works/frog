#if !os(macOS)
import SwiftUI

/// Markdown blocks, laid out as on the Mac (the same gaps, headings, lists, quotes, tables and
/// code cards) in SwiftUI text. While the answer streams it writes itself in, as `InkReveal`
/// does on the Mac: at a reading pace on the display's clock, fresh words in frog green settling
/// into ink, and what hasn't been reached drawn clear so nothing reflows. Under Reduce Motion
/// text simply appears.
struct MessageText: View {
    let blocks: [MarkdownBlock]
    var streaming = false
    @State private var pen = InkPen()
    /// Seen streaming: this view writes it in. A finished message is simply there.
    @State private var inks: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if inks == true, !reduceMotion, !pen.settled {
                TimelineView(.animation) { ctx in
                    let now = ctx.date.timeIntervalSinceReferenceDate
                    let total = Self.length(blocks)
                    let shown = pen.advance(now: now, total: total, streaming: streaming)
                    BlocksView(blocks: blocks, ink: pen.ink(revealed: shown, now: now))
                        .onChange(of: pen.caughtUp(streaming: streaming, total: total)) { _, done in
                            if done { pen.settle() }
                        }
                }
            } else {
                BlocksView(blocks: blocks, ink: nil)
            }
        }
        .onAppear { if inks == nil { inks = streaming } }
    }

    /// Characters to write in: every block's text, in order.
    static func length(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { $0 + BlocksView.text($1).count }
    }
}

/// The blocks themselves, each inked over its stretch of the whole.
private struct BlocksView: View {
    let blocks: [MarkdownBlock]
    let ink: Ink?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(placed.enumerated()), id: \.offset) { _, p in
                block(p.block, from: p.start)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var placed: [(block: MarkdownBlock, start: Int)] {
        var start = 0
        return blocks.map { b in
            defer { start += Self.text(b).count }
            return (b, start)
        }
    }

    static func text(_ b: MarkdownBlock) -> String {
        switch b {
        case .paragraph(let s), .quote(let s): s
        case .heading(_, let s): s
        case .code(_, let s): s
        case .bullet(_, _, let s): s
        case .rule: ""
        case .table(let header, _, let rows): (header + rows.flatMap { $0 }).joined(separator: " ")
        }
    }

    @ViewBuilder
    private func block(_ b: MarkdownBlock, from start: Int) -> some View {
        switch b {
        case .paragraph(let s):
            Text(inked(Markdown.inline(s), from: start)).lineSpacing(3)
        case .heading(let level, let s):
            Text(inked(Markdown.inline(s), from: start))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
                .opacity(ink.map { $0.revealed > start ? 1 : 0 } ?? 1)
        case .bullet(let indent, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(inked(Markdown.inline(s), from: start)).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                Text(inked(Markdown.inline(s), from: start)).foregroundStyle(.secondary).lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let align, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { i, h in
                            Text(Markdown.inline(h)).fontWeight(.semibold).gridColumnAlignment(Self.alignment(align, i))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(Markdown.inline(cell)) }
                        }
                    }
                }
                .font(.callout)
            }
            .opacity(ink.map { $0.revealed > start ? 1 : 0 } ?? 1)
        }
    }

    private static func alignment(_ align: [TableAlign], _ i: Int) -> HorizontalAlignment {
        switch align.indices.contains(i) ? align[i] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// The pen's colors over this block's stretch: drying runs in green, the unwritten tail clear.
    private func inked(_ source: AttributedString, from start: Int) -> AttributedString {
        guard let ink else { return source }
        var a = source
        let n = a.characters.count
        func range(_ lo: Int, _ hi: Int) -> Range<AttributedString.Index>? {
            let lo = max(0, lo - start), hi = min(n, hi - start)
            guard hi > lo else { return nil }
            let from = a.characters.index(a.startIndex, offsetBy: lo)
            return from..<a.characters.index(from, offsetBy: hi - lo)
        }
        for (r, t) in ink.drying {
            if let rr = range(r.lowerBound, r.upperBound) { a[rr].foregroundColor = Ink.color(t) }
        }
        if let hidden = range(ink.revealed, start + n) { a[hidden].foregroundColor = .clear }
        return a
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

    /// The Mac's `InkReveal` pace: how long a word takes to settle, how far behind arrival the
    /// pen may run while streaming and after, and the slowest pace (about reading speed).
    static let inkTime = 0.42
    static let lagStreaming = 0.32
    static let lagDone = 0.1
    static let minRate = 42.0

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

/// How far the ink has got: character ranges over the message.
struct Ink {
    let revealed: Int
    /// Recently written stretches and how dry they are (0 fresh … 1 dry).
    let drying: [(Range<Int>, Double)]

    /// Frog green, fading into the text's own color. Four steps are enough for the eye.
    static func color(_ t: Double) -> Color {
        Color.frog.mix(with: .primary, by: (t * 4).rounded(.down) / 4)
    }
}
#endif

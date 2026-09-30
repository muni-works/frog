import SwiftUI

/// Markdown, simply: fenced code as monospaced blocks, the rest with inline styling. With `ink`,
/// only what the pen has reached shows, the newest words still drying green.
struct MessageBody: View {
    let rendered: RenderedMessage
    var ink: Ink?

    init(text: String) {
        rendered = RenderedMessage(text)
    }

    init(rendered: RenderedMessage, ink: Ink?) {
        self.rendered = rendered
        self.ink = ink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(placed.enumerated()), id: \.offset) { _, p in
                switch p.piece {
                case .prose(let a):
                    Text(inked(a, from: p.start)).textSelection(.enabled)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(inked(AttributedString(s), from: p.start))
                            .font(.callout.monospaced())
                            .padding(10)
                    }
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    /// Each piece with where it starts in the rendered text.
    private var placed: [(piece: RenderedMessage.Piece, start: Int)] {
        var start = 0
        return rendered.pieces.map { p in
            defer { start += p.count }
            return (p, start)
        }
    }

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

    enum Piece { case prose(String), code(String) }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var prose: [Substring] = [], code: [Substring] = []
        var inCode = false
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] } else { flushProse() }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return out
    }

    /// Inline markdown, plus headings and bullets made to read well without a block renderer.
    static func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (i, line) in s.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            var text = String(line)
            var heading = false
            if let m = text.firstMatch(of: /^#{1,6}\s+/) {
                text.removeSubrange(m.range)
                heading = true
            } else if let m = text.firstMatch(of: /^(\s*)[-*]\s+/) {
                text.replaceSubrange(m.range, with: m.output.1 + "•  ")
            }
            var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
            if heading { a.font = .body.weight(.semibold) }
            out.append(a)
        }
        return out
    }
}

/// Three dots, like someone typing, before the first word of an answer.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let phase = (t * 2.2 - Double(i) * 0.22).truncatingRemainder(dividingBy: 1.4)
                    let lift = phase < 0.5 ? sin(phase / 0.5 * .pi) : 0
                    Circle()
                        .frame(width: 8, height: 8)
                        .opacity(0.35 + 0.5 * lift)
                        .offset(y: -3 * lift)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: .capsule)
        }
        .accessibilityLabel("frog is working")
    }
}

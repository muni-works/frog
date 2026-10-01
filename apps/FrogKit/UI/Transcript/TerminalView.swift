import SwiftUI

/// Converts text with ANSI SGR escapes (colors, bold, dim, italic, underline) into an
/// AttributedString. Other escape sequences are dropped.
enum ANSI {
    private static let base: [Color] = [
        Color(white: 0.25), Color(red: 0.94, green: 0.33, blue: 0.31), Color(red: 0.35, green: 0.78, blue: 0.40),
        Color(red: 0.93, green: 0.76, blue: 0.29), Color(red: 0.36, green: 0.58, blue: 0.96), Color(red: 0.78, green: 0.45, blue: 0.90),
        Color(red: 0.33, green: 0.78, blue: 0.84), Color(white: 0.85),
    ]
    private static let bright: [Color] = [
        Color(white: 0.5), Color(red: 1, green: 0.47, blue: 0.45), Color(red: 0.47, green: 0.9, blue: 0.52),
        Color(red: 1, green: 0.86, blue: 0.42), Color(red: 0.5, green: 0.7, blue: 1), Color(red: 0.88, green: 0.6, blue: 1),
        Color(red: 0.45, green: 0.9, blue: 0.95), .white,
    ]

    private struct Style {
        var fg: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var style = Style()
        var rest = Substring(text)
        while let esc = rest.firstIndex(of: "\u{1B}") {
            append(rest[..<esc], style, to: &out)
            rest = rest[rest.index(after: esc)...]
            guard rest.first == "[" else {
                // Not CSI: drop the escape and one following character.
                rest = rest.dropFirst()
                continue
            }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(where: { ("@"..."~").contains($0) }) else { break }
            let params = rest[..<end]
            let command = rest[end]
            rest = rest[rest.index(after: end)...]
            if command == "m" {
                apply(params.split(separator: ";").map { Int($0) ?? 0 }, to: &style)
            }
        }
        append(rest, style, to: &out)
        return out
    }

    private static func append(_ s: Substring, _ style: Style, to out: inout AttributedString) {
        guard !s.isEmpty else { return }
        var part = AttributedString(String(s).replacingOccurrences(of: "\r", with: ""))
        if let fg = style.fg { part.foregroundColor = style.dim ? fg.opacity(0.6) : fg }
        else if style.dim { part.foregroundColor = .secondary }
        var font = Font.system(.caption, design: .monospaced)
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        part.font = font
        if style.underline { part.underlineStyle = .single }
        out += part
    }

    private static func apply(_ codes: [Int], to style: inout Style) {
        var codes = codes.isEmpty ? [0] : codes
        while !codes.isEmpty {
            let c = codes.removeFirst()
            switch c {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.fg = base[c - 30]
            case 90...97: style.fg = bright[c - 90]
            case 39: style.fg = nil
            case 38:
                if codes.first == 5, codes.count >= 2 {
                    style.fg = palette(codes[1])
                    codes.removeFirst(2)
                } else if codes.first == 2, codes.count >= 4 {
                    style.fg = Color(red: Double(codes[1]) / 255, green: Double(codes[2]) / 255, blue: Double(codes[3]) / 255)
                    codes.removeFirst(4)
                }
            case 48:
                // Background colors: skip their arguments.
                if codes.first == 5 { codes.removeFirst(min(2, codes.count)) }
                else if codes.first == 2 { codes.removeFirst(min(4, codes.count)) }
            default: break
            }
        }
    }

    /// xterm 256-color palette.
    private static func palette(_ n: Int) -> Color {
        switch n {
        case 0..<8: return base[n]
        case 8..<16: return bright[n - 8]
        case 16..<232:
            let i = n - 16
            let v = { (x: Int) in x == 0 ? 0.0 : (Double(x) * 40 + 55) / 255 }
            return Color(red: v(i / 36), green: v((i / 6) % 6), blue: v(i % 6))
        default:
            return Color(white: (Double(n - 232) * 10 + 8) / 255)
        }
    }
}

/// Monospaced, ANSI-colored output. `live` pins the view to the newest lines.
struct TerminalView: View {
    let text: String
    var live = false
    var maxHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            Text(ANSI.attributed(text.isEmpty ? "(no output)" : text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .defaultScrollAnchor(live ? .bottom : .top)
        .defaultScrollAnchor(live ? .bottom : .top, for: .sizeChanges)
        .frame(maxHeight: maxHeight)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
    }
}

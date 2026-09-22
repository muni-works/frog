import SwiftUI

/// Markdown blocks. Inline styling (bold, code, links) is left to `AttributedString`.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case rule
}

enum Markdown {
    /// Line-based block parser. Tolerates an unterminated code fence, since text streams in.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (lang: String, lines: [String])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: f.lang, text: f.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    f.lines.append(line)
                    fence = f
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                fence = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: heading, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let (marker, text) = listItem(trimmed) {
                flush()
                let indent = line.prefix(while: { $0 == " " }).count / 2
                blocks.append(.bullet(indent: indent, marker: marker, text: text))
                continue
            }
            paragraph.append(line)
        }
        flush()
        if let f = fence {
            blocks.append(.code(language: f.lang, text: f.lines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ s: String) -> (String, String)? {
        for m in ["- ", "* ", "• "] where s.hasPrefix(m) {
            return ("•", String(s.dropFirst(2)))
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", String(s.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Markdown.inline(s))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Markdown.inline(s))
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .code(let lang, let s):
            CodeBlock(language: lang, code: s)
        case .bullet(let indent, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Markdown.inline(s)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            Text(Markdown.inline(s))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 3)
                }
        case .rule:
            Divider()
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

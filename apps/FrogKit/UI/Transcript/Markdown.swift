import SwiftUI

/// Markdown blocks. Inline styling (bold, code, links) is left to `AttributedString`.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case rule
    /// A pipe table: header cells, per-column alignment, then rows (ragged rows are padded).
    case table(header: [String], align: [TableAlign], rows: [[String]])
}

enum TableAlign: Hashable {
    case leading, center, trailing
}

enum Markdown {
    /// Line-based block parser. Tolerates an unterminated code fence, since text streams in.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (lang: String, lines: [String])?
        var table: (header: [String], align: [TableAlign], rows: [[String]])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if let t = table {
                blocks.append(.table(header: t.header, align: t.align, rows: t.rows))
                table = nil
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
            // A pipe row continues a table; a header row plus an alignment row starts one.
            if let cells = tableRow(trimmed) {
                if var t = table {
                    t.rows.append(cells)
                    table = t
                    continue
                }
                // The header can follow paragraph text directly (as in GitHub): what came before
                // it stays a paragraph of its own.
                if let last = paragraph.last,
                   let header = tableRow(last.trimmingCharacters(in: .whitespaces)),
                   let align = alignmentRow(cells, columns: header.count) {
                    paragraph.removeLast()
                    flush()
                    table = (header, align, [])
                    continue
                }
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

    /// The cells of a `| a | b |` line, or nil if it isn't one. Pipes inside inline code stay.
    static func tableRow(_ s: String) -> [String]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.count > 1 else { return nil }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for ch in t.dropFirst() {
            if escaped { cell.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(cell); cell = "" } else { cell.append(ch) }
        }
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `|---|:--:|--:|` under a header: one alignment per column, padded to `columns`.
    static func alignmentRow(_ cells: [String], columns: Int) -> [TableAlign]? {
        guard !cells.isEmpty, cells.allSatisfy({ c in
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }) else { return nil }
        var align: [TableAlign] = cells.map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
        while align.count < columns { align.append(.leading) }
        return align
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

/// Streaming text only grows at the end, so blocks before the last paragraph break (outside a
/// code fence) never change. Those are parsed once and cached; only the tail is re-parsed.
final class MarkdownCache {
    private var prefix = ""
    private var blocks: [MarkdownBlock] = []

    func blocks(for text: String) -> [MarkdownBlock] {
        let cut = Self.stableBoundary(text)
        let head = String(text[..<cut])
        if head != prefix {
            prefix = head
            blocks = Markdown.parse(head)
        }
        return blocks + Markdown.parse(String(text[cut...]))
    }

    /// End of the last blank line that isn't inside a code fence.
    static func stableBoundary(_ text: String) -> String.Index {
        var fences = 0
        var boundary = text.startIndex
        var lineStart = text.startIndex
        var previousBlank = false
        for i in text.indices where text[i] == "\n" {
            let line = text[lineStart..<i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fences += 1 }
            let blank = line.isEmpty
            if blank && !previousBlank && fences % 2 == 0 {
                boundary = text.index(after: i)
            }
            previousBlank = blank
            lineStart = text.index(after: i)
        }
        return boundary
    }
}

struct MarkdownView: View {
    let text: String
    /// Still arriving from the model: written in at a reading pace.
    var streaming = false
    @State private var cache = MarkdownCache()
    @Environment(\.turnSpace) private var space

    var body: some View {
        // One selectable text view per stretch of the message; a diagram is a card of its own.
        VStack(alignment: .leading, spacing: space.block) {
            ForEach(Array(Self.segments(cache.blocks(for: text)).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let blocks): MessageText(blocks: blocks, streaming: streaming)
                case .mermaid(let code): MermaidBlock(code: code)
                }
            }
        }
    }

    enum Segment {
        case text([MarkdownBlock])
        case mermaid(String)
    }

    static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var out: [Segment] = []
        var run: [MarkdownBlock] = []
        for block in blocks {
            if case .code(let lang, let code) = block, lang.lowercased() == "mermaid" {
                if !run.isEmpty { out.append(.text(run)); run = [] }
                out.append(.mermaid(code))
            } else {
                run.append(block)
            }
        }
        if !run.isEmpty { out.append(.text(run)) }
        return out
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Clipboard.copy(code)
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
            .padding(.horizontal, TurnSpace.Inset.roomy)
            .padding(.vertical, TurnSpace.Inset.snug)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlight.block(code, Highlight.lang(fence: language)))
                    .font(.system(.callout, design: .monospaced))
                    .padding(TurnSpace.Inset.roomy)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            #if os(macOS)
            Button("Save As…", systemImage: "square.and.arrow.down") { save() }
            #else
            ShareLink(item: code) { Label("Share", systemImage: "square.and.arrow.up") }
            #endif
        }
        .draggable(code)
    }

    private func copy() {
        Clipboard.copy(code)
    }

    #if os(macOS)
    private func save() {
        let panel = NSSavePanel()
        let ext = ["python": "py", "rust": "rs", "swift": "swift", "typescript": "ts", "javascript": "js",
                   "bash": "sh", "sh": "sh", "json": "json", "toml": "toml", "go": "go", "c": "c"][language.lowercased()]
        panel.nameFieldStringValue = "snippet" + (ext.map { ".\($0)" } ?? ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? code.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}

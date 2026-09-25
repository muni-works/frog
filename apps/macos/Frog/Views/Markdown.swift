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
                if paragraph.count == 1, let header = tableRow(paragraph[0]), let align = alignmentRow(cells, columns: header.count) {
                    paragraph = []
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
    @State private var cache = MarkdownCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(cache.blocks(for: text).enumerated()), id: \.offset) { _, block in
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
            if lang.lowercased() == "mermaid" {
                MermaidBlock(code: s)
            } else {
                CodeBlock(language: lang, code: s)
            }
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
        case .table(let header, let align, let rows):
            MarkdownTable(header: header, align: align, rows: rows)
        }
    }
}

/// A pipe table as a grid: a bold header, hairlines between rows, columns sized to content.
struct MarkdownTable: View {
    let header: [String]
    let align: [TableAlign]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(header[safe: c] ?? "", column: c)
                            .fontWeight(.semibold)
                    }
                }
                .background(Color.primary.opacity(0.05))
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    Divider().gridCellColumns(columns)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(row[safe: c] ?? "", column: c)
                        }
                    }
                }
            }
            .padding(1)
        }
        .scrollIndicators(.automatic)
        .background(Color.primary.opacity(0.02), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(.vertical, 2)
    }

    private func cell(_ text: String, column: Int) -> some View {
        let a = align[safe: column] ?? .leading
        return Text(Markdown.inline(text))
            .font(.callout)
            .multilineTextAlignment(a == .center ? .center : a == .trailing ? .trailing : .leading)
            .frame(maxWidth: 360, alignment: a == .center ? .center : a == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(a == .center ? .center : a == .trailing ? .trailing : .leading)
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
                Text(Highlight.block(code, Highlight.lang(fence: language)))
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            Button("Save As…", systemImage: "square.and.arrow.down") { save() }
        }
        .draggable(code)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        let ext = ["python": "py", "rust": "rs", "swift": "swift", "typescript": "ts", "javascript": "js",
                   "bash": "sh", "sh": "sh", "json": "json", "toml": "toml", "go": "go", "c": "c"][language.lowercased()]
        panel.nameFieldStringValue = "snippet" + (ext.map { ".\($0)" } ?? ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? code.write(to: url, atomically: true, encoding: .utf8)
    }
}

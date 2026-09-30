#if os(macOS)
import AppKit
import SwiftUI

/// Markdown blocks in one AppKit text view, so a selection runs across paragraphs, lists, quotes,
/// code and tables the way it does in a document (SwiftUI can't select from one `Text` into
/// the next). TextKit 1, for text blocks and tables. Streaming only replaces the blocks that
/// changed, so a selection in what's already there survives new text arriving.
struct MessageText: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    /// Still arriving: reveal it at a reading pace, inking in (see `InkReveal`).
    var streaming = false

    func makeNSView(context: Context) -> MessageTextView {
        let view = MessageTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFontPanel = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.layoutManager?.delegate = view
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.reveal.streaming = streaming
        view.show(blocks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 640
        return CGSize(width: width, height: view.height(for: width))
    }
}

final class MessageTextView: NSTextView, @MainActor NSLayoutManagerDelegate {
    private var shown: [MarkdownBlock] = []
    /// Where each shown block's text sits in the storage, separator included.
    private var ranges: [NSRange] = []
    /// The code blocks laid over their attachments, in order.
    private var codeViews: [NSHostingView<CodeOverlay>] = []
    private var placePending = false
    lazy var reveal = InkReveal(view: self)

    // MARK: Content

    func show(_ blocks: [MarkdownBlock]) {
        guard blocks != shown, let storage = textStorage else { return }
        // Blocks before the first difference are untouched; everything after is rebuilt.
        let keep = zip(blocks, shown).prefix(while: { $0 == $1 }).count
        let from = keep < ranges.count ? ranges[keep].location : storage.length
        let tail = NSMutableAttributedString()
        var newRanges = Array(ranges.prefix(keep))
        for (i, block) in blocks.enumerated().dropFirst(keep) {
            let piece = MessageStyle.piece(block, first: i == 0)
            newRanges.append(NSRange(location: from + tail.length, length: piece.length))
            tail.append(piece)
        }
        // Code blocks are measured before they go in, so their lines are the right height from
        // the first layout.
        let before = codeAttachments(in: NSRange(location: 0, length: from)).count
        let incoming = Self.attachments(in: tail, range: NSRange(location: 0, length: tail.length))
        while codeViews.count > before + incoming.count { codeViews.removeLast().removeFromSuperview() }
        for (j, item) in incoming.enumerated() {
            item.cell.height = measure(item.cell, at: before + j)
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: tail)
        storage.endEditing()
        shown = blocks
        ranges = newRanges
        needsLayout = true
        invalidateIntrinsicContentSize()
        reveal.textChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reveal.windowChanged()
    }

    /// A code block shows once the pen reaches it.
    func syncCodeVisibility() {
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            let visible = reveal.codeVisible(at: item.range.location)
            let alpha: CGFloat = visible ? 1 : 0
            guard codeViews[i].alphaValue != alpha else { continue }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.3 : 0
                codeViews[i].animator().alphaValue = alpha
            }
        }
    }

    // MARK: Size

    func height(for width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, container.containerSize.width != newSize.width {
            container.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
    }

    override func layout() {
        super.layout()
        placeCode()
    }

    /// Text above a code block moved (it streamed in, or the width changed): move the block
    /// with it, once layout has settled.
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd: Bool) {
        guard !codeViews.isEmpty, !placePending else { return }
        placePending = true
        DispatchQueue.main.async { [weak self] in
            self?.placePending = false
            self?.placeCode()
        }
    }

    // The transcript scrolls; this view never does.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // MARK: Code blocks

    /// Code blocks keep their own look and horizontal scrolling: each is one attachment
    /// character in the text, as tall as the block, with the SwiftUI `CodeBlock` laid over it.
    private func codeAttachments(in range: NSRange? = nil) -> [(range: NSRange, cell: CodeAttachmentCell)] {
        guard let storage = textStorage else { return [] }
        return Self.attachments(in: storage, range: range ?? NSRange(location: 0, length: storage.length))
    }

    private static func attachments(in text: NSAttributedString, range: NSRange) -> [(range: NSRange, cell: CodeAttachmentCell)] {
        var out: [(NSRange, CodeAttachmentCell)] = []
        text.enumerateAttribute(.attachment, in: range) { value, range, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? CodeAttachmentCell { out.append((range, cell)) }
        }
        return out
    }

    /// Puts the block's view in place `index` (making it if needed) and returns its height.
    private func measure(_ cell: CodeAttachmentCell, at index: Int) -> CGFloat {
        let overlay = CodeOverlay(language: cell.language, code: cell.code)
        if index < codeViews.count {
            codeViews[index].rootView = overlay
        } else {
            let host = NSHostingView(rootView: overlay)
            host.sizingOptions = []
            addSubview(host)
            codeViews.append(host)
        }
        let width = textContainer?.containerSize.width ?? 0
        let size = NSHostingController(rootView: overlay)
            .sizeThatFits(in: CGSize(width: width > 0 && width < 10_000 ? width : 600, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    private func placeCode() {
        guard let layout = layoutManager, let container = textContainer else { return }
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            let glyphs = layout.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
            layout.ensureLayout(forGlyphRange: glyphs)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            codeViews[i].frame = NSRect(x: rect.minX, y: rect.maxY - item.cell.height, width: bounds.width - rect.minX,
                                        height: item.cell.height)
        }
    }

    private func isSelected(_ range: NSRange) -> Bool {
        selectedRanges.contains { NSIntersectionRange($0.rangeValue, range).length > 0 }
    }

    /// A selection that covers a code block shows it selected, too.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            let selected = isSelected(item.range)
            if codeViews[i].rootView.selected != selected {
                codeViews[i].rootView = CodeOverlay(language: item.cell.language, code: item.cell.code, selected: selected)
            }
        }
    }

    /// Copying (or dragging) a selection writes each code block's code where its attachment is.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let text = selectedRanges.map { value -> String in
            let range = value.rangeValue
            var out = ""
            storage.enumerateAttribute(.frogCode, in: range) { code, sub, _ in
                if let code = code as? String {
                    out += code
                } else {
                    out += storage.attributedSubstring(from: sub).string.replacingOccurrences(of: "\u{FFFC}", with: "")
                }
            }
            return out
        }.joined(separator: "\n")
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }
}

/// A code block laid over its place in the text, tinted while a selection covers it.
struct CodeOverlay: View {
    let language: String
    let code: String
    var selected = false

    var body: some View {
        CodeBlock(language: language, code: code)
            .textSelection(.enabled)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .selectedTextBackgroundColor).opacity(0.45))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The space a code block takes in the text: the full line width, as tall as the block.
final class CodeAttachmentCell: NSTextAttachmentCell {
    let language: String
    let code: String
    var height: CGFloat = 60

    init(language: String, code: String) {
        self.language = language
        self.code = code
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        language = ""
        code = ""
        super.init(coder: coder)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(0, lineFrag.width - position.x), height: height)
    }

    override func cellSize() -> NSSize { NSSize(width: 1, height: height) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func wantsToTrackMouse() -> Bool { false }
}

extension NSAttributedString.Key {
    /// Marks a code block's attachment with its code, for copying.
    static let frogCode = NSAttributedString.Key("frogCode")
}

/// How each markdown block looks as attributed text.
enum MessageStyle {
    static let blockGap: CGFloat = 10

    static var body: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    static func paragraph(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        configure(p)
        return p
    }

    /// One block, preceded by the newline that separates it from the last (unless it's first).
    static func piece(_ block: MarkdownBlock, first: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !first { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
        let gap: CGFloat = first ? 0 : blockGap
        switch block {
        case .paragraph(let s):
            out.append(inline(s, font: body, style: paragraph { $0.paragraphSpacingBefore = gap }))
        case .heading(let level, let s):
            let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 13
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            out.append(inline(s, font: font, style: paragraph { $0.paragraphSpacingBefore = gap + 4 }))
        case .bullet(let indent, let marker, let s):
            let lead = CGFloat(indent) * 16
            let markerWidth = (marker as NSString).size(withAttributes: [.font: body]).width
            let head = lead + max(markerWidth, 10) + 8
            let style = paragraph {
                $0.paragraphSpacingBefore = gap
                $0.firstLineHeadIndent = lead
                $0.headIndent = head
                $0.tabStops = [NSTextTab(textAlignment: .left, location: head)]
            }
            out.append(NSAttributedString(string: "\(marker)\t", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            out.append(inline(s, font: body, style: style))
        case .quote(let s):
            // The gap above is padding, not margin: a margin after a table collapses into it.
            let block = QuoteTextBlock(gap: gap)
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(gap, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            let text = inline(s, font: body, style: paragraph { $0.textBlocks = [block] })
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: text.length))
            out.append(text)
        case .rule:
            let block = RuleTextBlock()
            block.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setValue(100, type: .percentageValueType, for: .width)
            out.append(NSAttributedString(string: "\u{200B}", attributes: [
                .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: paragraph { $0.textBlocks = [block] },
            ]))
        case .code(let language, let code):
            out.append(codeBlock(language: language, code: code, gap: gap))
        case .table(let header, let align, let rows):
            out.append(table(header: header, align: align, rows: rows, gap: gap))
        }
        return out
    }

    private static func codeBlock(language: String, code: String, gap: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = CodeAttachmentCell(language: language, code: code)
        let text = NSMutableAttributedString(attachment: attachment)
        let whole = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: paragraph { $0.lineSpacing = 0; $0.paragraphSpacingBefore = gap }, range: whole)
        text.addAttribute(.frogCode, value: code, range: whole)
        return text
    }

    private static func table(header: [String], align: [TableAlign], rows: [[String]], gap: CGFloat) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let table = NSTextTable()
        table.numberOfColumns = max(columns, 1)
        table.collapsesBorders = true
        table.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        let font = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        for (r, row) in ([header] + rows).enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 { cell.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
                let a = align[safe: c] ?? .leading
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.alignment = a == .center ? .center : a == .trailing ? .right : .left
                let text = inline(row[safe: c] ?? "", font: r == 0 ? .systemFont(ofSize: 12, weight: .semibold) : font, style: style)
                out.append(text)
                // Every cell is its own paragraph; the message's last cell ends the table.
                if !(r == rows.count && c == columns - 1) { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
            }
        }
        return out
    }

    /// Inline markdown (bold, italic, code, links, strikethrough) as attributed text.
    static func inline(_ s: String, font: NSFont, style: NSParagraphStyle) -> NSMutableAttributedString {
        let parsed = Markdown.inline(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .foregroundColor: NSColor.labelColor]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !traits.isEmpty {
                    f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits)),
                               size: f.pointSize) ?? f
                }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}

/// A quote: a rounded bar down its leading edge.
final class QuoteTextBlock: NSTextBlock {
    /// Space above the quote, inside the block; the bar starts below it.
    let gap: CGFloat

    init(gap: CGFloat) {
        self.gap = gap
        super.init()
    }

    required init?(coder: NSCoder) {
        gap = 0
        super.init(coder: coder)
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let bar = NSRect(x: frameRect.minX, y: frameRect.minY + gap, width: 3, height: frameRect.height - gap)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// A horizontal rule: a hairline across the middle of an empty line.
final class RuleTextBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        NSColor.separatorColor.setFill()
        NSRect(x: frameRect.minX, y: frameRect.midY, width: frameRect.width, height: 0.5).fill()
    }
}
#endif

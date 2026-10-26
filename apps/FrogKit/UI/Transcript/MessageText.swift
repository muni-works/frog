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
        // Draws inline code's rounded backgrounds (see `InlineCodeLayoutManager`).
        view.textContainer?.replaceLayoutManager(InlineCodeLayoutManager())
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
        // This runs inside SwiftUI's graph update: nothing in here may invalidate the layout
        // SwiftUI is computing (see `MessageTextView.updating`).
        view.updating = true
        defer { view.updating = false }
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
    /// Measures code blocks: one SwiftUI graph for the view's life, rather than a new one built
    /// and torn down for every streamed token.
    private lazy var sizer: NSHostingController<CodeOverlay> = {
        let c = NSHostingController(rootView: CodeOverlay(language: "", code: ""))
        c.sizingOptions = []
        return c
    }()
    /// Inside `MessageText.updateNSView`, i.e. inside SwiftUI's update of the transcript.
    /// Invalidating this view's size from there changes an input of the graph mid-update (an
    /// AttributeGraph corruption suspect, docs/design/attributegraph-corruption.md); SwiftUI
    /// measures the view again after the update anyway, so it waits for the next turn.
    var updating = false
    private var invalidatePending = false

    /// The view's height changed: tell SwiftUI, now if it's safe, else right after this update.
    func sizeChanged() {
        guard updating else {
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            return
        }
        guard !invalidatePending else { return }
        invalidatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidatePending = false
            self.invalidateIntrinsicContentSize()
            self.superview?.needsLayout = true
        }
    }

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
        while codeViews.count > before + incoming.count {
            // Not torn down mid-update: hidden now, gone once SwiftUI's update is over.
            let gone = codeViews.removeLast()
            gone.isHidden = true
            DispatchQueue.main.async { gone.removeFromSuperview() }
        }
        for (j, item) in incoming.enumerated() {
            item.cell.height = measure(item.cell, at: before + j)
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: tail)
        storage.endEditing()
        shown = blocks
        ranges = newRanges
        needsLayout = true
        sizeChanged()
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
        let full = ceil(layout.usedRect(for: container).height)
        // While the pen is still writing, the view is only as tall as what's written: text that
        // has arrived but isn't revealed yet is laid out, drawn clear, and shouldn't make the
        // transcript scroll, stop at the top, or count as "more lines" before anyone can read it.
        guard let written = reveal.writtenHeight() else { return full }
        return min(full, ceil(written))
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
        sizer.rootView = overlay
        let size = sizer.sizeThatFits(in: CGSize(width: width > 0 && width < 10_000 ? width : 600, height: .greatestFiniteMagnitude))
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
    /// Inline code: a rounded tint behind it, hugging the glyphs rather than the line.
    static let frogInlineCode = NSAttributedString.Key("frogInlineCode")
}

/// Inline code sits on a small rounded tint, like claude.ai's: around the glyphs' own height,
/// not the line's (which includes the leading and a paragraph's space above). A plain
/// `.backgroundColor` can only fill the line fragment, square. Drawn under the selection.
final class InlineCodeLayoutManager: NSLayoutManager {
    static let pad: CGFloat = 2
    static let radius: CGFloat = 4

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            storage.enumerateAttribute(.frogInlineCode, in: chars) { value, range, _ in
                guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                // Not written in yet (see `InkReveal`): no tint ahead of the pen.
                if temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor == .clear { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var g = glyphs.location
                // One rounded rect per line the code wraps across.
                while g < NSMaxRange(glyphs) {
                    var line = NSRange()
                    let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
                    let run = NSIntersectionRange(line, glyphs)
                    guard run.length > 0 else { break }
                    let span = boundingRect(forGlyphRange: run, in: container)
                    let baseline = fragment.minY + location(forGlyphAt: run.location).y
                    let rect = NSRect(x: span.minX - Self.pad, y: baseline - font.ascender - 1,
                                      width: span.width + Self.pad * 2, height: font.ascender - font.descender + 2)
                    NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                                 xRadius: Self.radius, yRadius: Self.radius).fill()
                    g = NSMaxRange(run)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// How each markdown block looks as attributed text. Spacing comes from `TurnSpace`, so a
/// message reads with the transcript's rhythm: taller line height within a paragraph, more
/// room between blocks, and list items tighter than blocks.
enum MessageStyle {
    /// The density setting's scale, as `piece` is built on a text-queue (AppKit) thread at times.
    static var blockGap: CGFloat { TurnSpace.current.paragraph }
    static var listGap: CGFloat { TurnSpace.current.list }
    static var lineHeight: CGFloat { TurnSpace.current.line }

    static var body: NSFont { .systemFont(ofSize: TurnType.body) }

    static func paragraph(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineHeight
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
            let font = NSFont.systemFont(ofSize: TurnType.heading(level), weight: .semibold)
            // More room above a heading than below it: it belongs to what follows.
            out.append(inline(s, font: font, style: paragraph { $0.paragraphSpacingBefore = gap + TurnSpace.Inset.row }))
        case .bullet(let indent, let marker, let s):
            let lead = CGFloat(indent) * TurnType.body
            let markerWidth = (marker as NSString).size(withAttributes: [.font: body]).width
            let head = lead + max(markerWidth, TurnSpace.Inset.card) + TurnSpace.Inset.row
            let style = paragraph {
                $0.paragraphSpacingBefore = gap
                $0.paragraphSpacing = listGap
                $0.firstLineHeadIndent = lead
                $0.headIndent = head
                $0.tabStops = [NSTextTab(textAlignment: .left, location: head)]
            }
            out.append(NSAttributedString(string: "\(marker)\t", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: TurnType.body, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            out.append(inline(s, font: body, style: style))
        case .quote(let s):
            // The gap above is padding, not margin: a margin after a table collapses into it.
            let block = QuoteTextBlock(gap: gap)
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(gap, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(TurnSpace.Inset.roomy, type: .absoluteValueType, for: .padding, edge: .minX)
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
        let font = NSFont.systemFont(ofSize: TurnType.small)
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
                let text = inline(row[safe: c] ?? "", font: r == 0 ? .systemFont(ofSize: TurnType.small, weight: .semibold) : font, style: style)
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
                    attrs[.frogInlineCode] = true
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

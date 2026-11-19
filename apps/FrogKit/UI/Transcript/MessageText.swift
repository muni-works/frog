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
    /// Where this view sits in the transcript column, for the parity metrics (nil: not measured).
    var metricsOrigin: CGPoint? = nil

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
        // Every NSTextView in the window hears every view's frame change (AppKit looks for an
        // enclosing clip view), so in a long transcript each row placed paid for all the others.
        // Nothing here tracks frames: the container width is set from `setFrameSize`.
        view.postsFrameChangedNotifications = false
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        // This runs inside SwiftUI's graph update: nothing in here may invalidate the layout
        // SwiftUI is computing (see `MessageTextView.updating`).
        view.updating = true
        defer { view.updating = false }
        view.reveal.streaming = streaming
        view.show(blocks, indent: context.environment.transcriptEdge.indent)
        view.metricsOrigin = context.environment.metricsHidden ? nil : metricsOrigin
        if metricsOrigin != nil { DispatchQueue.main.async { view.reportMetrics() } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 640 + MessageTextView.gutterRoom
        return CGSize(width: width, height: view.height(for: width))
    }
}

final class MessageTextView: NSTextView, @MainActor NSLayoutManagerDelegate {
    /// Room in the gutter, left of the text: the view reaches this far past the column's edge
    /// (`MeasuredText` pulls it out), and its text starts this far in, on the edge. A top-level
    /// list's markers and the plate of code that starts a line hang there (spec, "Two lines");
    /// a view can't draw outside its own bounds.
    static let gutterRoom: CGFloat = Tokens.Transcript.Layout.hang

    override var textContainerOrigin: NSPoint { NSPoint(x: Self.gutterRoom, y: 0) }

    private var shown: [MarkdownBlock] = []
    /// Prose indents by this in a narrow pane (`TranscriptEdge`); code and tables don't.
    private var indent: CGFloat = 0
    var metricsOrigin: CGPoint?
    /// Where each shown block's text sits in the storage, separator included.
    private var ranges: [NSRange] = []
    /// The code blocks laid over their attachments, in order. Nil until the block comes near
    /// the visible rect: a hosting view per code block is a large part of building a row, and a
    /// jump through a long transcript builds rows it never shows.
    private var codeViews: [NSHostingView<CodeOverlay>?] = []
    private var placePending = false
    lazy var reveal = InkReveal(view: self)
    /// Measures code blocks: one SwiftUI graph for every message, rather than one per view (a
    /// row a jump lands on is a new view) or a new one for every streamed token.
    private static let sizer: NSHostingController<CodeOverlay> = {
        let c = NSHostingController(rootView: CodeOverlay(language: "", code: ""))
        c.sizingOptions = []
        return c
    }()
    private struct CodeKey: Hashable { let lines: Int, titled: Bool, line: CGFloat }
    /// Code block heights by line count. A block never wraps (it scrolls sideways), so its
    /// height is its header plus its lines, whatever the code or the width: a block streaming
    /// in is measured once per new line, not once per token (a SwiftUI sizing pass each).
    private static var codeHeights: [CodeKey: CGFloat] = [:]
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

    func show(_ blocks: [MarkdownBlock], indent: CGFloat = 0) {
        let reindent = indent != self.indent
        guard blocks != shown || reindent, let storage = textStorage else { return }
        self.indent = indent
        // Blocks before the first difference are untouched; everything after is rebuilt.
        let keep = reindent ? 0 : zip(blocks, shown).prefix(while: { $0 == $1 }).count
        let from = keep < ranges.count ? ranges[keep].location : storage.length
        let tail = NSMutableAttributedString()
        var newRanges = Array(ranges.prefix(keep))
        for (i, block) in blocks.enumerated().dropFirst(keep) {
            let piece = MessageStyle.piece(block, after: i == 0 ? nil : blocks[i - 1], indent: indent)
            newRanges.append(NSRange(location: from + tail.length, length: piece.length))
            tail.append(piece)
        }
        // Code blocks are measured before they go in, so their lines are the right height from
        // the first layout.
        // One attachment per code block (`MessageStyle.codeBlock`): counted from the blocks
        // kept, not by walking the storage before them on every streamed delta.
        let before = shown.prefix(keep).reduce(0) { n, b in if case .code = b { n + 1 } else { n } }
        let incoming = Self.attachments(in: tail, range: NSRange(location: 0, length: tail.length))
        while codeViews.count > before + incoming.count {
            // Not torn down mid-update: hidden now, gone once SwiftUI's update is over.
            guard let gone = codeViews.removeLast() else { continue }
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
        stopHearingFrames()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        stopHearingFrames()
    }

    /// NSTextView listens to every view's frame change in the process (it's looking for a clip
    /// view to adopt), so every frame change in the transcript paid once per row's text view.
    /// This view never scrolls itself; it doesn't need to.
    private func stopHearingFrames() {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    }

    /// The transcript scrolled: code blocks coming into view get their views.
    @objc private func clipScrolled(_ note: Notification) {
        if codeViews.contains(where: { $0 == nil }) { placeCode() }
    }

    override func viewWillDraw() {
        if codeViews.contains(where: { $0 == nil }) { placeCode() }
        super.viewWillDraw()
    }

    /// A code block shows once the pen reaches it.
    func syncCodeVisibility() {
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            guard let host = codeViews[i] else { continue }
            let visible = reveal.codeVisible(at: item.range.location)
            let alpha: CGFloat = visible ? 1 : 0
            guard host.alphaValue != alpha else { continue }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.3 : 0
                host.animator().alphaValue = alpha
            }
        }
    }

    // MARK: Size

    func height(for viewWidth: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        let width = max(0, viewWidth - Self.gutterRoom)
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

    /// Each block as a row of the parity metrics: a paragraph, heading, quote or list item is
    /// `prose`, a code block or table `code` (docs/design/parity/README.md, "Metrics").
    func reportMetrics() {
        guard let origin = metricsOrigin, let layout = layoutManager, let container = textContainer,
              let storage = textStorage else { return }
        layout.ensureLayout(for: container)
        let key = "text-\(ObjectIdentifier(self).hashValue)"
        for (i, block) in shown.enumerated() where i < ranges.count {
            var range = ranges[i]
            // Drop the newline that separates it from the block before.
            if i > 0, range.length > 0 { range = NSRange(location: range.location + 1, length: range.length - 1) }
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var kind = TranscriptMetrics.Kind.prose
            var text = (storage.string as NSString).substring(with: range)
            var firstChar = range.location
            var sub = "prose"
            switch block {
            case .code(_, let code): kind = .code; text = code; sub = "code"
            case .table: kind = .code; sub = "table"
            case .heading: sub = "heading"
            case .bullet where storage.attribute(.frogHungMarker, at: range.location, effectiveRange: nil) is HungMarker:
                // The words start after the hung marker and its space (both zero-width).
                let n = ((storage.attribute(.frogHungMarker, at: range.location, effectiveRange: nil) as? HungMarker)?.mark as NSString?)?.length ?? 1
                sub = "list item"
                firstChar += n + 1
                text = (text as NSString).substring(from: min((text as NSString).length, n + 1))
            case .bullet:
                sub = "list item"
                // The marker isn't the item's words: they start after its tab.
                let tab = (text as NSString).range(of: "\t")
                if tab.location != NSNotFound {
                    firstChar += tab.location + 1
                    text = (text as NSString).substring(from: tab.location + 1)
                }
            case .rule: continue
            default: break
            }
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let box: CGRect
            if case .table = block {
                // The table's own box: its cells' blocks, not the glyphs inside their padding.
                var cells = CGRect.null
                var at = range.location
                while at < NSMaxRange(range) {
                    var run = NSRange()
                    let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: &run) as? NSParagraphStyle
                    for b in style?.textBlocks ?? [] {
                        cells = cells.union(layout.boundsRect(for: b, glyphRange: layout.glyphRange(forCharacterRange: run, actualCharacterRange: nil)))
                    }
                    at = max(at + 1, NSMaxRange(run))
                }
                box = cells.isNull ? layout.boundingRect(forGlyphRange: glyphs, in: container) : cells
            } else if kind == .prose {
                // Every prose line is one fixed line box: the block starts a line above its
                // first line's bottom (the line fragment also holds the paragraph's gap above).
                let line = MessageStyle.lineBox
                box = CGRect(x: 0, y: first.maxY - line, width: container.size.width, height: last.maxY - first.maxY + line)
            } else {
                box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            }
            let g = layout.glyphIndexForCharacter(at: firstChar)
            let fragment = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let x = fragment.minX + layout.location(forGlyphAt: g).x
            let font = storage.attribute(.font, at: firstChar, effectiveRange: nil) as? NSFont
            let k = "\(key)-\(i)"
            if sub == "prose", storage.attribute(.frogInlineCode, at: firstChar, effectiveRange: nil) != nil { sub = "prose (opens with code)" }
            TranscriptMetrics.shared.set(k, kind: kind, text: text,
                                         box: box.offsetBy(dx: origin.x, dy: origin.y), fontSize: font?.pointSize ?? 0, sub: sub)
            TranscriptMetrics.shared.setFirst(k, x: origin.x + (kind == .code ? box.minX : x))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(0, newSize.width - Self.gutterRoom)
        if let container = textContainer, container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            // Measured again at the width it settles at (a block measured before is unbounded).
            if metricsOrigin != nil { DispatchQueue.main.async { [weak self] in self?.reportMetrics() } }
        }
    }

    override func layout() {
        super.layout()
        placeCode()
        let room = NSRect(x: 0, y: 0, width: Self.gutterRoom, height: bounds.height)
        if gutter.superview == nil {
            gutter.text = self
            addSubview(gutter)
        }
        if gutter.frame != room { gutter.frame = room }
    }

    /// Draws the hung markers and plate overhangs (`GutterMarks`).
    private let gutter = GutterMarks()

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        gutter.needsDisplay = true
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

    /// Updates the block's view in place `index` if it has one (holding the place if not) and
    /// returns its height.
    private func measure(_ cell: CodeAttachmentCell, at index: Int) -> CGFloat {
        let overlay = CodeOverlay(language: cell.language, code: cell.code)
        if index < codeViews.count {
            codeViews[index]?.rootView = overlay
        } else {
            codeViews.append(nil)
        }
        cell.placeholder = codeViews[index] == nil
        let lines = max(1, cell.code.reduce(into: 1) { n, c in if c == "\n" { n += 1 } })
        let key = CodeKey(lines: lines, titled: !cell.language.isEmpty, line: TurnSpace.current.line)
        if let height = Self.codeHeights[key] { return height }
        let width: CGFloat = 600
        Self.sizer.rootView = CodeOverlay(language: cell.language.isEmpty ? "" : "x",
                                          code: Array(repeating: "x", count: lines).joined(separator: "\n"))
        let height = ceil(Self.sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if Self.codeHeights.count > 4096 { Self.codeHeights.removeAll() }
        Self.codeHeights[key] = height
        return height
    }

    private var makePending = false

    /// Places the code views; one that's missing and near the visible rect is made `now`, or
    /// on the next turn of the run loop, after the frame that brought its row in.
    private func placeCode(now: Bool = false) {
        guard let layout = layoutManager, let container = textContainer else { return }
        // Only what's on screen: making blocks ahead (measured: half a screen) put a jump's
        // neighbours into the frame after it. A block scrolled into view shows its placeholder
        // for one frame instead.
        let near = visibleRect
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            let glyphs = layout.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
            layout.ensureLayout(forGlyphRange: glyphs)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let x = textContainerOrigin.x + rect.minX
            let frame = NSRect(x: x, y: rect.maxY - item.cell.height, width: bounds.width - x,
                               height: item.cell.height)
            if let host = codeViews[i] {
                host.frame = frame
            } else if !near.isEmpty, frame.intersects(near) {
                guard now else {
                    if !makePending {
                        makePending = true
                        DispatchQueue.main.async { [weak self] in
                            self?.makePending = false
                            self?.placeCode(now: true)
                        }
                    }
                    continue
                }
                let host = NSHostingView(rootView: CodeOverlay(language: item.cell.language, code: item.cell.code,
                                                               selected: isSelected(item.range)))
                host.sizingOptions = []
                host.postsFrameChangedNotifications = false
                host.alphaValue = reveal.codeVisible(at: item.range.location) ? 1 : 0
                host.frame = frame
                addSubview(host)
                codeViews[i] = host
                item.cell.placeholder = false
                setNeedsDisplay(frame)
            }
        }
    }

    private func isSelected(_ range: NSRange) -> Bool {
        selectedRanges.contains { NSIntersectionRange($0.rangeValue, range).length > 0 }
    }

    /// A selection that covers a code block shows it selected, too.
    /// Some code block may be drawn selected.
    private var codeTinted = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // TextKit sets an empty selection on every storage edit (each streamed delta): with
        // nothing selected now or before, no code block's tint changes.
        let selecting = ranges.contains { $0.rangeValue.length > 0 }
        guard selecting || codeTinted else { return }
        codeTinted = selecting
        for (i, item) in codeAttachments().enumerated() where i < codeViews.count {
            guard let host = codeViews[i] else { continue }
            let selected = isSelected(item.range)
            if host.rootView.selected != selected {
                host.rootView = CodeOverlay(language: item.cell.language, code: item.cell.code, selected: selected)
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
                    RoundedRectangle(cornerRadius: TurnSpace.Card.radius)
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

    /// No view laid over it yet (it's made the run-loop turn after its row comes in; see
    /// `MessageTextView.placeCode`): draw the block's card and plain code, for that frame.
    var placeholder = true

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        guard placeholder, (controlView as? MessageTextView)?.reveal.codeVisible(at: charIndex) ?? true else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: TurnSpace.Card.radius, yRadius: TurnSpace.Card.radius).fill()
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        let head = NSAttributedString(string: language, attributes: [
            .font: NSFont.systemFont(ofSize: caption.pointSize, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let top = cellFrame.minY + TurnSpace.Inset.snug
        head.draw(at: NSPoint(x: cellFrame.minX + TurnSpace.Inset.roomy, y: top))
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let body = NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        let y = top + ceil(head.size().height) + TurnSpace.Inset.snug + 1 + TurnSpace.Inset.roomy
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: cellFrame).addClip()
        body.draw(at: NSPoint(x: cellFrame.minX + TurnSpace.Inset.roomy, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }
    override func wantsToTrackMouse() -> Bool { false }
}

extension NSAttributedString.Key {
    /// Marks a code block's attachment with its code, for copying.
    static let frogCode = NSAttributedString.Key("frogCode")
    /// Inline code: a rounded tint behind it, hugging the glyphs rather than the line.
    static let frogInlineCode = NSAttributedString.Key("frogInlineCode")
    /// A list marker drawn in the gutter, left of where its zero-width character sits.
    static let frogHungMarker = NSAttributedString.Key("frogHungMarker")
}

/// A hung list marker (`.frogHungMarker`): what to draw, right-aligned a gap before the words.
final class HungMarker: NSObject {
    let mark: String
    let color: NSColor
    let font: NSFont
    let gap: CGFloat

    init(mark: String, color: NSColor, font: NSFont, gap: CGFloat) {
        self.mark = mark
        self.color = color
        self.font = font
        self.gap = gap
    }
}

/// Inline code sits on a small rounded tint, like claude.ai's: around the glyphs' own height,
/// not the line's (which includes the leading and a paragraph's space above). A plain
/// `.backgroundColor` can only fill the line fragment, square. Drawn under the selection.
final class InlineCodeLayoutManager: NSLayoutManager {
    static let pad: CGFloat = 2
    static let radius: CGFloat = 4

    /// Inline code's plates for the characters in `chars`, in the text container's coordinates:
    /// one rounded rect per line the code wraps across. Code that starts a line has its plate
    /// reach `codePad` past the container's leading edge (drawn by `GutterMarks`).
    func plates(in chars: NSRange) -> [NSRect] {
        guard let storage = textStorage, let container = textContainers.first else { return [] }
        var out: [NSRect] = []
        storage.enumerateAttribute(.frogInlineCode, in: chars) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            // Not written in yet (see `InkReveal`): no tint ahead of the pen.
            if temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor == .clear { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var g = glyphs.location
            while g < NSMaxRange(glyphs) {
                var line = NSRange()
                let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
                let run = NSIntersectionRange(line, glyphs)
                guard run.length > 0 else { break }
                let span = boundingRect(forGlyphRange: run, in: container)
                let baseline = fragment.minY + location(forGlyphAt: run.location).y
                // The words are padded in the line (`MessageStyle.codePad`: room before the
                // run, and a kern on its last character that `span` already includes).
                out.append(NSRect(x: span.minX - MessageStyle.codePad, y: baseline - font.ascender - Self.pad,
                                  width: span.width + MessageStyle.codePad, height: font.ascender - font.descender + Self.pad * 2))
                g = NSMaxRange(run)
            }
        }
        return out
    }

    /// The hung list markers for the characters in `chars`: each mark and where to draw it, in
    /// the container's coordinates (left of the container's edge, drawn by `GutterMarks`).
    func hungMarkers(in chars: NSRange) -> [(NSAttributedString, NSPoint)] {
        guard let storage = textStorage else { return [] }
        var out: [(NSAttributedString, NSPoint)] = []
        storage.enumerateAttribute(.frogHungMarker, in: chars) { value, range, _ in
            guard let m = value as? HungMarker else { return }
            // Not written in yet (see `InkReveal`): the pen hasn't reached the item.
            if temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor == .clear { return }
            let g = glyphIndexForCharacter(at: range.location)
            let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let at = location(forGlyphAt: g)
            let s = NSAttributedString(string: m.mark, attributes: [.font: m.font, .foregroundColor: m.color])
            out.append((s, NSPoint(x: fragment.minX + at.x - m.gap - s.size().width, y: fragment.minY + at.y - m.font.ascender)))
        }
        return out
    }

    static let plateColor = NSColor.labelColor.withAlphaComponent(0.09)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        Self.plateColor.setFill()
        for rect in plates(in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) {
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// What a message draws in the gutter, left of its text: hung list markers and the overhang of
/// a code plate that starts a line. NSTextView clips its own drawing to the text container, so
/// these are drawn by this subview over the text view's room (`MessageTextView.gutterRoom`).
/// Clicks go through to the text.
final class GutterMarks: NSView {
    weak var text: MessageTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let text, let layout = text.layoutManager as? InlineCodeLayoutManager, let storage = text.textStorage else { return }
        let origin = text.textContainerOrigin
        let all = NSRange(location: 0, length: storage.length)
        InlineCodeLayoutManager.plateColor.setFill()
        for rect in layout.plates(in: all) where rect.minX < 0 {
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                         xRadius: InlineCodeLayoutManager.radius, yRadius: InlineCodeLayoutManager.radius).fill()
        }
        for (mark, at) in layout.hungMarkers(in: all) {
            mark.draw(at: NSPoint(x: origin.x + at.x, y: origin.y + at.y))
        }
    }
}

/// How each markdown block looks as attributed text. Spacing comes from `TurnSpace`, so a
/// message reads with the transcript's rhythm: taller line height within a paragraph, room
/// between paragraphs, more above a heading, and list items tighter than paragraphs.
enum MessageStyle {
    /// Every line of prose is one fixed box (`Tokens.Transcript.body`, 14 / 22), as on the web:
    /// a paragraph of two lines is 44 tall, and the gap between two is `paragraph` exactly.
    static let lineBox: CGFloat = Tokens.Transcript.body.line
    /// Prose stops here (`Layout.prose`); code and tables use the whole column.
    static let measure: CGFloat = Tokens.Transcript.Layout.prose
    /// Inline code's plate pads its words this much each side (the web's `.md code` padding):
    /// room in the line mid-sentence; at the start of a line the plate overhangs the edge.
    static let codePad: CGFloat = TurnSpace.Inset.tight

    /// The body face: IBM Plex Sans, like the rest of the transcript (SF until the fonts load).
    static var body: NSFont { plex(TurnType.body) }

    static func plex(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard PlexFonts.registered, let base = NSFont(name: "IBM Plex Sans", size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        guard weight != .regular else { return base }
        // IBMPlexSans.ttf is a variable font: a weight is a point on its `wght` axis (a weight
        // trait on the descriptor resolves to the regular face).
        let value: Double = switch weight {
        case .medium: 500
        case .semibold: 600
        case .bold, .heavy, .black: 700
        default: 400
        }
        let wght = 0x7767_6874 // 'wght'
        let d = base.fontDescriptor.addingAttributes([.variation: [NSNumber(value: wght): NSNumber(value: value)]])
        return NSFont(descriptor: d, size: size) ?? base
    }

    static func mono(_ size: CGFloat) -> NSFont {
        guard PlexFonts.registered, let f = NSFont(name: "IBM Plex Mono", size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return f
    }

    /// A prose paragraph's style: the fixed line box, glyphs centred in it as CSS does.
    static func paragraph(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineBox
        p.maximumLineHeight = lineBox
        configure(p)
        return p
    }

    /// Prose's measure and indent on a paragraph style (code and tables keep the column).
    private static func prose(_ p: NSMutableParagraphStyle, indent: CGFloat) {
        p.firstLineHeadIndent += indent
        p.headIndent += indent
        p.tailIndent = measure + indent
    }

    /// Raises glyphs to the middle of the fixed line box: TextKit puts a taller line's extra
    /// room above the text, CSS splits it.
    static func centring(_ font: NSFont) -> CGFloat {
        let natural = ceil(font.ascender - font.descender)
        return max(0, (lineBox - natural) / 2).rounded(.down)
    }

    /// One block, preceded by the newline that separates it from the one before (nil: it's
    /// first). Its gap depends on that block (see `TurnSpace.Scale.gap`); streaming rebuilds
    /// from the first block that changed, so a block is never left with a stale neighbor.
    static func piece(_ block: MarkdownBlock, after previous: MarkdownBlock?, indent: CGFloat = 0) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if previous != nil { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
        let gap = TurnSpace.current.gap(block, after: previous)
        switch block {
        case .paragraph(let s):
            out.append(inline(s, font: body, style: paragraph { $0.paragraphSpacingBefore = gap; prose($0, indent: indent) }))
        case .heading(let level, let s):
            let font = plex(TurnType.heading(level), weight: .semibold)
            out.append(inline(s, font: font, style: paragraph { $0.paragraphSpacingBefore = gap; prose($0, indent: indent) }))
        case .bullet(let level, let marker, let s):
            // The item's words start on the column's edge (a nested list one marker column in
            // per level), wrapped lines under them; the marker ends a gap before the words. A
            // top-level marker hangs in the gutter, as a line's mark does (spec, the left line).
            let head = CGFloat(level) * TurnType.markerColumn
            let mark = TurnType.marker(marker, indent: level)
            let markFont = NSFont.monospacedDigitSystemFont(ofSize: TurnType.body, weight: .regular)
            let markWidth = ceil((mark as NSString).size(withAttributes: [.font: markFont]).width)
            let markStart = head + indent - TurnType.markerGap - markWidth
            // A bullet is a small glyph: in the text's own color it weighs what a number does in
            // secondary.
            let markColor: NSColor = marker == "•" ? .labelColor : .secondaryLabelColor
            if markStart < 0 {
                // No room before the words: the marker is kept in the text (a copied list
                // reads "• item") but takes no width and is drawn in the gutter by
                // `InlineCodeLayoutManager`.
                let style = paragraph {
                    $0.paragraphSpacingBefore = gap
                    $0.firstLineHeadIndent = head
                    $0.headIndent = head
                    prose($0, indent: indent)
                }
                let space = ceil((" " as NSString).size(withAttributes: [.font: markFont]).width * 100) / 100
                let room = (mark as NSString).size(withAttributes: [.font: markFont]).width
                out.append(NSAttributedString(string: mark, attributes: [
                    .font: markFont, .foregroundColor: NSColor.clear, .paragraphStyle: style, .kern: -room,
                    .frogHungMarker: HungMarker(mark: mark, color: markColor, font: markFont, gap: TurnType.markerGap),
                ]))
                out.append(NSAttributedString(string: " ", attributes: [
                    .font: markFont, .foregroundColor: NSColor.clear, .paragraphStyle: style, .kern: -space,
                ]))
                out.append(inline(s, font: body, style: style))
            } else {
                let style = paragraph {
                    $0.paragraphSpacingBefore = gap
                    // The marker starts where it ends flush with the words (right-aligned by its
                    // measured width, not a leading tab, so a copied list reads "• item").
                    $0.firstLineHeadIndent = head - TurnType.markerGap - markWidth
                    $0.headIndent = head
                    $0.tabStops = [NSTextTab(textAlignment: .left, location: head + indent)]
                    prose($0, indent: indent)
                }
                out.append(NSAttributedString(string: "\(mark)\t", attributes: [
                    .font: markFont, .foregroundColor: markColor, .paragraphStyle: style,
                ]))
                out.append(inline(s, font: body, style: style))
            }
        case .quote(let s):
            // The gap above is padding, not margin: a margin after a table collapses into it.
            let block = QuoteTextBlock(gap: gap)
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(gap, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(TurnSpace.Inset.roomy, type: .absoluteValueType, for: .padding, edge: .minX)
            let text = inline(s, font: body, style: paragraph { $0.textBlocks = [block]; prose($0, indent: indent) })
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
        // A paragraph or heading that starts in Arabic or Hebrew reads right to left, right
        // aligned, whatever the Mac's own language (`.natural` follows the locale, not the text).
        switch block {
        case .paragraph(let t), .heading(_, let t):
            if startsRightToLeft(t) {
                out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, r, _ in
                    guard let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                    p.baseWritingDirection = .rightToLeft
                    out.addAttribute(.paragraphStyle, value: p, range: r)
                }
            }
        default: break
        }
        return out
    }

    /// The first strong letter is from a right-to-left script.
    static func startsRightToLeft(_ s: String) -> Bool {
        for u in s.unicodeScalars where u.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(u.value) || (0xFB1D...0xFDFF).contains(u.value) || (0xFE70...0xFEFF).contains(u.value)
        }
        return false
    }

    private static func codeBlock(language: String, code: String, gap: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = CodeAttachmentCell(language: language, code: code)
        let text = NSMutableAttributedString(attachment: attachment)
        let whole = NSRange(location: 0, length: text.length)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = gap
        text.addAttribute(.paragraphStyle, value: style, range: whole)
        text.addAttribute(.frogCode, value: code, range: whole)
        return text
    }

    private static func table(header: [String], align: [TableAlign], rows: [[String]], gap: CGFloat) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let table = NSTextTable()
        table.numberOfColumns = max(columns, 1)
        table.collapsesBorders = true
        table.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        let font = plex(TurnType.small)
        let out = NSMutableAttributedString()
        for (r, row) in ([header] + rows).enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                // Quiet, like claude.ai: no cell borders at all (a bordered grid is the
                // loudest thing in the column) — the header's wash and the row padding do
                // the separating.
                cell.setWidth(0, type: .absoluteValueType, for: .border)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 { cell.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
                let a = align[safe: c] ?? .leading
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.alignment = a == .center ? .center : a == .trailing ? .right : .left
                let text = inline(row[safe: c] ?? "", font: r == 0 ? plex(TurnType.small, weight: .semibold) : font, style: style)
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
        // Prose sits in a fixed line box (`paragraph`): centre its glyphs in it.
        let fixed = style.maximumLineHeight > 0
        var style = style
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .foregroundColor: NSColor.labelColor]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) {
                    // Medium, not bold: an emphasized run mid-sentence ("**1. The watcher
                    // rescans…**" with a full stop) reads as a false heading in bold, fighting
                    // the paragraph. Headings and table headers keep their semibold, set at
                    // the font level.
                    f = plex(font.pointSize, weight: .medium)
                }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    f = mono(font.pointSize - 1)
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
            if fixed { attrs[.baselineOffset] = centring(f) }
            let code = attrs[.frogInlineCode] != nil
            if code {
                // The plate's padding is room in the line: before the code (on the character
                // before it) and after. Code that opens a paragraph keeps its letters on the
                // column's edge and its plate overhangs by the padding (spec, the left line), as
                // at the start of a wrapped line.
                if out.length > 0 {
                    out.addAttribute(.kern, value: codePad, range: NSRange(location: out.length - 1, length: 1))
                }
            }
            let piece = NSMutableAttributedString(string: text, attributes: attrs)
            if code, piece.length > 0 {
                piece.addAttribute(.kern, value: codePad, range: NSRange(location: piece.length - 1, length: 1))
            }
            out.append(piece)
        }
        // A paragraph that opened with code: every run takes the shifted first indent.
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
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

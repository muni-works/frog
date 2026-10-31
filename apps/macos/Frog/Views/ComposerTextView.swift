import AppKit
import SwiftUI

/// Lets the composer act on the text view (inserting a picked `@` mention).
@MainActor
final class ComposerController {
    weak var textView: NSTextView?

    /// The `@query` token touching the cursor, if any.
    static func mentionRange(in tv: NSTextView) -> NSRange? {
        let s = tv.string as NSString
        let cursor = tv.selectedRange().location
        guard cursor != NSNotFound, cursor <= s.length else { return nil }
        var i = cursor
        while i > 0 {
            let c = s.character(at: i - 1)
            if c == 0x40 /* @ */ {
                let before = i - 1 == 0 ? 0x20 : s.character(at: i - 2)
                guard before == 0x20 || before == 0x0A || before == 0x09 else { return nil }
                return NSRange(location: i - 1, length: cursor - (i - 1))
            }
            if c == 0x20 || c == 0x0A || c == 0x09 { return nil }
            i -= 1
        }
        return nil
    }

    func insertMention(_ path: String) {
        guard let tv = textView, let range = Self.mentionRange(in: tv) else { return }
        tv.insertText("@\(path) ", replacementRange: range)
    }

    /// Replace everything typed so far (e.g. with a picked `/skill`).
    func replaceAll(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text, replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    /// Insert text at the cursor (e.g. `@path` mentions for dropped files).
    func insert(_ text: String) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Put the cursor (a zero-length range) somewhere, e.g. where a restored draft left it.
    func select(_ range: NSRange) {
        guard let tv = textView else { return }
        tv.setSelectedRange(range)
    }

    // MARK: Dictation

    /// Where dictated text sits in the field, and what was last put there.
    private var dictated: (range: NSRange, text: String)?
    /// Set while dictation writes to the field, so its own edits don't move `dictated`.
    private var dictating = false

    /// Dictated text goes at the cursor (after any selection), leaving what's typed alone.
    func beginDictation() {
        guard let tv = textView else { return }
        let length = (tv.string as NSString).length
        let sel = tv.selectedRange()
        let at = sel.location == NSNotFound ? length : min(sel.location + sel.length, length)
        dictated = (NSRange(location: at, length: 0), "")
    }

    /// Put the transcript where the previous one was, the unsettled words dimmed. False when the
    /// field changed under it (sent, cleared or typed over), so dictation should stop.
    func showDictation(_ transcript: DictationTranscript) -> Bool {
        guard let tv = textView, let storage = tv.textStorage, let d = dictated else { return false }
        let s = tv.string as NSString
        guard d.range.location + d.range.length <= s.length, s.substring(with: d.range) == d.text else {
            endDictation()
            return false
        }
        let (final, volatile) = transcript.parts
        let body = final + volatile
        let before = d.range.location > 0 ? s.character(at: d.range.location - 1) : nil
        let after = d.range.location + d.range.length < s.length ? s.character(at: d.range.location + d.range.length) : nil
        let pad = DictationTranscript.padding(before: before, after: after, empty: body.isEmpty)
        let text = pad.lead + body + pad.trail
        let sel = tv.selectedRange()
        dictating = true
        if tv.shouldChangeText(in: d.range, replacementString: text) {
            storage.replaceCharacters(in: d.range, with: NSAttributedString(string: text, attributes: tv.typingAttributes))
            tv.didChangeText()
        }
        dictating = false
        let range = NSRange(location: d.range.location, length: (text as NSString).length)
        dictated = (range, text)
        // The cursor follows the words when it was at their end; elsewhere it stays put.
        let end = d.range.location + d.range.length
        let bodyEnd = range.location + (pad.lead + body as NSString).length
        if sel.location >= end, sel.location != NSNotFound {
            let moved = sel.location == end ? bodyEnd : sel.location + range.length - d.range.length
            tv.setSelectedRange(NSRange(location: moved, length: sel.location == end ? 0 : sel.length))
        } else if sel.location > d.range.location {
            tv.setSelectedRange(NSRange(location: bodyEnd, length: 0))
        }
        if let layout = tv.layoutManager {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            let dim = NSRange(location: range.location + (pad.lead + final as NSString).length, length: (volatile as NSString).length)
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: dim)
        }
        tv.scrollRangeToVisible(NSRange(location: bodyEnd, length: 0))
        return true
    }

    /// Dictation is over: whatever it left in the field is ordinary text now.
    func endDictation() {
        dictated = nil
        guard let tv = textView else { return }
        tv.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    /// Someone edited the field: keep track of where dictated text went, or let it go if they
    /// edited it.
    fileprivate func noteEdit(_ range: NSRange, replacement: Int) {
        guard !dictating, let d = dictated else { return }
        guard let moved = DictationTranscript.shift(d.range, byEdit: range, replacement: replacement) else {
            endDictation()
            return
        }
        dictated = (moved, d.text)
    }
}

enum MentionKey {
    case up, down, accept, cancel
}

/// A multi-line input backed by NSTextView.
///
/// SwiftUI's TextEditor can reset its cursor when unrelated state re-renders the view mid-typing,
/// which scrambles what the user types. This only writes to the text view when the bound value
/// really differs (e.g. cleared after sending), and handles Return / Shift-Return / Esc / arrows
/// through AppKit's command selectors.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var controller: ComposerController
    var onSubmit: () -> Void
    var onEscape: () -> Bool
    /// Called with the `@query` at the cursor (without the `@`), or nil when there isn't one.
    var onMention: (String?) -> Void = { _ in }
    /// Keys while mention suggestions are showing. Return true if handled.
    var onMentionKey: (MentionKey) -> Bool = { _ in false }
    /// Tab outside mentions (accepting a suggested next prompt). Return true if handled.
    var onTab: () -> Bool = { false }
    /// Pasted images (copied images or image files). Nil: paste as usual.
    var onPasteImages: (([ToolImage]) -> Void)?
    var minHeight: CGFloat = 22
    var maxHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = PastingTextView(frame: .zero)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.pasteImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onPasteImages?(images)
        }
        tv.acceptsImages = { [weak coordinator = context.coordinator] in coordinator?.parent.onPasteImages != nil }
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 5
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        controller.textView = tv
        DispatchQueue.main.async {
            // A pane that comes back (a switch, a split) mustn't pull the caret out of whatever
            // the user is already in — a search field, the terminal, another pane's composer.
            if let window = tv.window, window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(tv)
            }
            context.coordinator.fitHeightNow(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.fitHeightNow(tv)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // The mention check comes first: it's a scan of the token under the cursor, where the
            // height is a full layout pass, and the suggestion list should answer the keystroke.
            reportMention(tv)
            updateHeight(tv)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let replacementString {
                parent.controller.noteEdit(range, replacement: (replacementString as NSString).length)
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            reportMention(tv)
        }

        private func reportMention(_ tv: NSTextView) {
            let query = ComposerController.mentionRange(in: tv).map {
                (tv.string as NSString).substring(with: NSRange(location: $0.location + 1, length: $0.length - 1))
            }
            parent.onMention(query)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let mentionKey: MentionKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)): .accept
            case #selector(NSResponder.cancelOperation(_:)): .cancel
            default: nil
            }
            if let key = mentionKey, parent.onMentionKey(key) {
                return true
            }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }

        /// A height update waiting for the current run loop turn to end.
        private var heightScheduled = false

        /// Fit the field to its text. Deferred to the next run loop turn, once per turn: the
        /// write invalidates the composer's SwiftUI view (which rebuilds its controls, pickers
        /// and popover anchors), and doing that from inside AppKit's text-change callback puts
        /// the re-render in the middle of the edit. By the next turn the text view has laid
        /// itself out for drawing anyway, so `usedRect` costs nothing.
        func updateHeight(_ tv: NSTextView) {
            guard !heightScheduled else { return }
            heightScheduled = true
            DispatchQueue.main.async { [weak self, weak tv] in
                self?.heightScheduled = false
                guard let self, let tv else { return }
                self.applyHeight(tv)
            }
        }

        private func applyHeight(_ tv: NSTextView) {
            guard let container = tv.textContainer, let layout = tv.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + tv.textContainerInset.height * 2
            let h = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(h - parent.height) > 0.5 {
                parent.height = h
            }
        }

        /// Fit it now, for the two places that are already off the edit (the first layout, and
        /// a binding write from SwiftUI), so the field never flashes at the wrong height.
        func fitHeightNow(_ tv: NSTextView) {
            heightScheduled = false
            applyHeight(tv)
        }
    }
}

/// The composer's text view: pasting an image (or an image file) attaches it instead of
/// dropping it on the floor, as a plain-text view otherwise would.
final class PastingTextView: NSTextView {
    var pasteImages: (([ToolImage]) -> Void)?
    var acceptsImages: () -> Bool = { false }

    /// A plain-text view only reads strings, so it greys out Paste when the clipboard holds just
    /// an image (a screenshot copied with ⌃⇧⌘4) and ⌘V never reaches `paste`.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), acceptsImages(),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if acceptsImages() {
            // Image files (copied in Finder) attach; so does image data with no text alongside.
            let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let images = files.contains(where: Attachments.isImage) || pb.string(forType: .string) == nil
                ? Attachments.images(on: pb) : []
            if !images.isEmpty {
                pasteImages?(images)
                return
            }
        }
        super.paste(sender)
    }

    /// A text view takes file drops as their paths; an image file dropped here attaches instead.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if acceptsImages(), files.contains(where: Attachments.isImage) {
            let images = Attachments.images(on: pb)
            if !images.isEmpty {
                pasteImages?(images)
                return true
            }
        }
        return super.performDragOperation(sender)
    }
}

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
            tv.window?.makeFirstResponder(tv)
            context.coordinator.updateHeight(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight(tv)
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
            updateHeight(tv)
            reportMention(tv)
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

        func updateHeight(_ tv: NSTextView) {
            guard let container = tv.textContainer, let layout = tv.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + tv.textContainerInset.height * 2
            let h = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(h - parent.height) > 0.5 {
                parent.height = h
            }
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

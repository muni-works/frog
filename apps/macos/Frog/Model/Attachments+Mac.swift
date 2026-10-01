import AppKit

/// The Mac's ways in: copied images and image files on the pasteboard, and AppKit images.
/// Resizing and encoding are shared (FrogKit/Core/Attachments.swift).
extension Attachments {
    static func image(from ns: NSImage) -> ToolImage? {
        ns.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(image(from:))
    }

    /// Images on the pasteboard (copied images or image files), or none.
    static func images(on pb: NSPasteboard) -> [ToolImage] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let found = urls.compactMap(image(at:))
            if !found.isEmpty { return found }
        }
        guard let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] else { return [] }
        return images.compactMap(image(from:))
    }
}

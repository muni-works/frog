import AppKit
import UniformTypeIdentifiers

/// Images attached to a message: resized so the long side is at most 1568 px (what vision
/// models use anyway), then PNG for screenshots and graphics, JPEG for photos.
enum Attachments {
    static let maxSide: CGFloat = 1568

    static func image(from data: Data) -> ToolImage? {
        guard let src = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap(rep) else { return nil }
        return encode(scaled(src))
    }

    static func image(from ns: NSImage) -> ToolImage? {
        guard let src = rep(ns) else { return nil }
        return encode(scaled(src))
    }

    static func image(at url: URL) -> ToolImage? {
        guard isImage(url), let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data)
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
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

    private static func rep(_ ns: NSImage) -> NSBitmapImageRep? {
        guard let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    private static func scaled(_ src: NSBitmapImageRep) -> NSBitmapImageRep {
        let w = CGFloat(src.pixelsWide), h = CGFloat(src.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1, let cg = src.cgImage else { return src }
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage().map(NSBitmapImageRep.init(cgImage:)) ?? src
    }

    private static func encode(_ rep: NSBitmapImageRep) -> ToolImage? {
        // Photos compress far better as JPEG; screenshots and graphics stay sharp as PNG.
        let png = rep.representation(using: .png, properties: [:])
        let jpeg = rep.hasAlpha ? nil : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        if let jpeg, let png, jpeg.count * 2 < png.count {
            return ToolImage(mime: "image/jpeg", data: jpeg.base64EncodedString())
        }
        return png.map { ToolImage(mime: "image/png", data: $0.base64EncodedString()) }
    }
}

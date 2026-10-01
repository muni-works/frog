import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images attached to a message: resized so the long side is at most 1568 px (what vision
/// models use anyway), then PNG for screenshots and graphics, JPEG for photos. The same on
/// every device, so a photo from the phone goes in as one dropped on the Mac does.
enum Attachments {
    static let maxSide: CGFloat = 1568

    /// An image file's bytes (any format ImageIO reads), upright and scaled down.
    static func image(from data: Data) -> ToolImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Scales and applies the photo's orientation in one go; never scales up.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return encode(cg)
    }

    static func image(from cg: CGImage) -> ToolImage? {
        encode(scaled(cg))
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func image(at url: URL) -> ToolImage? {
        guard isImage(url), let data = try? Data(contentsOf: url) else { return nil }
        return image(from: data)
    }

    private static func scaled(_ cg: CGImage) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return cg }
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage() ?? cg
    }

    private static func encode(_ cg: CGImage) -> ToolImage? {
        // Photos compress far better as JPEG; screenshots and graphics stay sharp as PNG.
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let png = data(cg, as: .png)
        let jpeg = opaque ? data(cg, as: .jpeg, quality: 0.85) : nil
        if let jpeg, let png, jpeg.count * 2 < png.count {
            return ToolImage(mime: "image/jpeg", data: jpeg.base64EncodedString())
        }
        return png.map { ToolImage(mime: "image/png", data: $0.base64EncodedString()) }
    }

    private static func data(_ cg: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, cg, props)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

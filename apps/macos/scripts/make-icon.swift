// Renders the Frog app icon at every macOS size: an ember-gradient flame on a warm dark squircle.
// Usage: swift scripts/make-icon.swift <output.appiconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the shape sits inside a ~10% margin.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Background: warm charcoal, lit from below like a frog mouth.
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.13, blue: 0.06, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.08, blue: 0.07, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.06, blue: 0.06, alpha: 1),
    ], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: rect, angle: 90)
    NSGradient(colors: [
        NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.55),
        NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0),
    ])!.draw(fromCenter: CGPoint(x: s / 2, y: rect.minY), radius: 0,
             toCenter: CGPoint(x: s / 2, y: rect.minY), radius: rect.width * 0.75, options: [])

    // Flame glyph, filled with an ember gradient.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .regular)
    let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let fs = flame.size
    let frect = CGRect(x: (s - fs.width) / 2, y: (s - fs.height) / 2 - s * 0.01, width: fs.width, height: fs.height)
    guard let cg = flame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError() }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: NSColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 0.8).cgColor)
    ctx.clip(to: frect, mask: cg)
    NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.30, blue: 0.08, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.86, blue: 0.45, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: frect, angle: 90)
    ctx.restoreGState()

    // Glass rim highlight
    NSColor.white.withAlphaComponent(0.10).setStroke()
    squircle.lineWidth = max(1, s * 0.004)
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: out.appending(path: name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appending(path: "Contents.json"))
print("wrote \(images.count) icons")

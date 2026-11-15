import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Frog

/// Drops that carry an image but no file URL (the floating screenshot thumbnail).
@MainActor
final class DropFilesTests: XCTestCase {
    private func image(_ type: UTType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type == .png ? .png : .tiff, properties: [:])!
    }

    func testImageDataWithNoURLBecomesAPNGAttachment() async throws {
        let png = image(.png)
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let urls = await DropFiles.urls(from: [provider], promises: [], into: DropFiles.folder())
        let url = try XCTUnwrap(urls.first)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertTrue(Attachments.isImage(url))
        XCTAssertNotNil(Attachments.image(at: url))
    }

    func testTIFFIsWrittenAsPNG() async throws {
        let provider = NSItemProvider(item: image(.tiff) as NSData, typeIdentifier: UTType.tiff.identifier)
        let found = await DropFiles.url(from: provider, into: DropFiles.folder())
        let url = try XCTUnwrap(found)
        XCTAssertEqual(url.pathExtension, "png")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
    }

    func testFileURLsPassThrough() async throws {
        let file = DropFiles.folder().appendingPathComponent("shot.png")
        try image(.png).write(to: file)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let urls = await DropFiles.urls(from: [provider], promises: [], into: DropFiles.folder())
        XCTAssertEqual(urls.map(\.lastPathComponent), ["shot.png"])
    }

    func testPromisesAreAccepted() {
        XCTAssertTrue(DropFiles.types.contains(.fileURL))
        XCTAssertTrue(DropFiles.types.contains(.image))
        XCTAssertFalse(DropFiles.promiseTypes.isEmpty)
    }
}

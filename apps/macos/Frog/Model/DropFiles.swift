import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What a drop on a conversation carries, as files the composer can attach. Finder gives file
/// URLs. The floating screenshot thumbnail gives a file promise and/or raw image data instead:
/// promised files are received into a temporary folder, and raw images are written there as PNG.
@MainActor
enum DropFiles {
    /// File promises, as AppKit reads them off a drag (SwiftUI's item providers can't).
    static let promiseTypes: [UTType] = NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }

    /// What the conversation accepts.
    static let types: [UTType] = [.fileURL, .image] + promiseTypes

    /// A fresh folder for one drop's files, under the app's temporary directory.
    static func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frog-drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The files a drop carries: each provider's file URL or image, else the promised files.
    /// `promises` must be read off the drag pasteboard while the drop is being performed.
    static func urls(from providers: [NSItemProvider], promises: [NSFilePromiseReceiver], into dir: URL) async -> [URL] {
        var urls: [URL] = []
        for (i, p) in providers.enumerated() {
            if let url = await url(from: p, into: dir, index: i) { urls.append(url) }
        }
        if urls.isEmpty {
            for r in promises { urls += await receive(r, into: dir) }
        }
        return urls
    }

    /// The promises on the drag pasteboard right now (during a drop).
    static func pendingPromises(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
    }

    /// One provider as a file: its file URL as is, or its image data written to `dir` as PNG.
    static func url(from provider: NSItemProvider, into dir: URL, index: Int = 0) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await fileURL(provider) {
            return url
        }
        // Prefer PNG, then whatever image type it offers first (TIFF from the thumbnail).
        let images = provider.registeredTypeIdentifiers.compactMap(UTType.init).filter { $0.conforms(to: .image) }
        guard let type = images.first(where: { $0 == .png }) ?? images.first,
              let data = await data(provider, type: type) else { return nil }
        let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "Dropped image\(index == 0 ? "" : " \(index + 1)")"
        let url = dir.appendingPathComponent(name).appendingPathExtension("png")
        guard let png = type == .png ? data : pngData(data), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
        }
    }

    /// Any image ImageIO reads, as PNG.
    static func pngData(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A promise's files, once the source has written them into `dir`.
    private static func receive(_ r: NSFilePromiseReceiver, into dir: URL) async -> [URL] {
        /// Touched only on `queue`, which runs one reader at a time.
        final class Received: @unchecked Sendable {
            var urls: [URL] = []
            var left: Int
            init(_ n: Int) { left = n }
        }
        let got = Received(max(r.fileNames.count, 1))
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return await withCheckedContinuation { done in
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                if error == nil { got.urls.append(url) }
                got.left -= 1
                if got.left == 0 { done.resume(returning: got.urls) }
            }
        }
    }
}

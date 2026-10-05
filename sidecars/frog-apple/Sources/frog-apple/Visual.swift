import AppKit
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers
import WebKit

func encodePNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw VisualError("could not create PNG encoder")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw VisualError("could not encode PNG") }
    return data as Data
}

struct VisualError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ message: String) { description = message }
}

/// A fresh ephemeral web view per capture, with a fixed CSS viewport and a deadline.
@MainActor
final class PageCapture: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var continuation: CheckedContinuation<Data, any Error>?
    var deadline: Task<Void, Never>?
    let settle: Int

    init(width: Int, height: Int, settle: Int) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        self.settle = settle
        super.init()
        web.navigationDelegate = self
    }

    func capture(_ url: URL) async throws -> Data {
        defer { deadline?.cancel(); web.stopLoading(); window.close() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(VisualError("page capture timed out after 30 seconds")))
            }
            if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { web.load(URLRequest(url: url)) }
        }
    }

    func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                _ = try await web.callAsyncJavaScript("if (document.fonts) await document.fonts.ready; await Promise.all(Array.from(document.images || []).map(i => i.complete ? Promise.resolve() : new Promise(r => {i.onload = r; i.onerror = r;}))); return true;", arguments: [:], in: nil, contentWorld: .page)
                try await Task.sleep(for: .milliseconds(settle))
                guard continuation != nil else { return }
                let options = WKSnapshotConfiguration()
                options.rect = web.bounds
                options.snapshotWidth = NSNumber(value: web.bounds.width)
                let image = try await web.takeSnapshot(configuration: options)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw VisualError("snapshot returned no image")
                }
                // WebKit snapshots have backing-scale pixels on Retina displays. Normalize
                // to the requested CSS viewport so comparisons use consistent dimensions.
                let width = Int(web.bounds.width), height = Int(web.bounds.height)
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw VisualError("could not allocate capture bitmap")
                }
                bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let resized = bitmap.makeImage() else { throw VisualError("could not resize capture") }
                finish(.success(try encodePNG(resized)))
            } catch { finish(.failure(error)) }
        }
    }
}

func screenshot(_ body: [String: Any], _ response: HTTPServer.Response) async {
    guard let raw = body["url"] as? String, let url = URL(string: raw),
          ["http", "https", "file"].contains(url.scheme ?? ""),
          url.user == nil, url.password == nil else {
        response.json(400, ["error": ["message": "url must use http, https or file without credentials"]]); return
    }
    let width = body["width"] as? Int ?? 1280
    let height = body["height"] as? Int ?? 720
    let settle = body["settle_ms"] as? Int ?? 200
    guard (64...2048).contains(width), (64...2048).contains(height), (0...5000).contains(settle) else {
        response.json(400, ["error": ["message": "invalid viewport or settle_ms"]]); return
    }
    do {
        let capture = await PageCapture(width: width, height: height, settle: settle)
        let png = try await capture.capture(url)
        response.json(200, ["data": [["b64_json": png.base64EncodedString()]], "width": width, "height": height])
    } catch { response.json(400, ["error": ["message": "\(error)"]]) }
}

func createImages(_ body: [String: Any], _ response: HTTPServer.Response) async {
    if #available(macOS 27, *) {
        response.json(503, ["error": ["message": "Apple removed programmatic ImageCreator generation on macOS 27+. Configure a remote or tang image endpoint."]]); return
    }
    guard let prompt = body["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          prompt.utf8.count <= 32000 else {
        response.json(400, ["error": ["message": "prompt must contain 1–32000 bytes of text"]]); return
    }
    let count = body["n"] as? Int ?? 1
    guard (1...4).contains(count) else { response.json(400, ["error": ["message": "n must be between 1 and 4"]]); return }
    // Apple chooses dimensions and does not expose seeds. Never imply deterministic output.
    if body["seed"] != nil {
        response.json(400, ["error": ["message": "Apple ImageCreator does not support seeds"]]); return
    }
    do {
        let creator = try await ImageCreator()
        let requested = body["model"] as? String ?? "apple/illustration"
        guard let style = creator.availableStyles.first(where: { requested.hasSuffix($0.id) }) ?? creator.availableStyles.first else {
            throw VisualError("no image styles are available")
        }
        var images: [[String: String]] = []
        for try await image in creator.images(for: [.text(prompt)], style: style, limit: count) {
            images.append(["b64_json": try encodePNG(image.cgImage).base64EncodedString()])
        }
        guard images.count == count else { throw VisualError("Apple returned \(images.count) of \(count) requested images") }
        response.json(200, ["data": images, "model": "apple/\(style.id)", "seed_supported": false])
    } catch { response.json(503, ["error": ["message": "Apple image generation unavailable: \(error)"]]) }
}

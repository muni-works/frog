import AppKit
import Network
import SwiftUI
import XCTest
@testable import Frog

/// The Preview pane to one design with the web's (docs/design/frog-web/README.md, "Preview"):
/// one 38 pt toolbar row whose every control sits inside it at 360, 420 and 560, the tools folded
/// into More below 400, the empty and failed states centred in the body, the progress line while
/// loading, and each device's frame inside the body in its shape. Drawn offscreen (a borderless
/// window that's never ordered in, never key), so nothing comes to the front. Snapshots go to
/// `$FROG_SNAPSHOT_DIR` (`docs/design/inspector` to refresh the checked-in ones,
/// `preview-<state>-mac-<theme>.png`), else `$TMPDIR/frog-snapshots/preview`.
@MainActor
final class PreviewLayoutTests: XCTestCase {
    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots/preview")
    }

    // MARK: The address and the devices

    func testAddressTakesAURLAPortOrHostPort() {
        XCTAssertEqual(PreviewAddress.url(from: "3000"), "http://localhost:3000")
        XCTAssertEqual(PreviewAddress.url(from: " 3000 "), "http://localhost:3000")
        XCTAssertEqual(PreviewAddress.url(from: ":3000/x"), "http://localhost:3000/x")
        XCTAssertEqual(PreviewAddress.url(from: "localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(PreviewAddress.url(from: "127.0.0.1:4321/docs"), "http://127.0.0.1:4321/docs")
        XCTAssertEqual(PreviewAddress.url(from: "https://example.com"), "https://example.com")
        XCTAssertNil(PreviewAddress.url(from: "  "))
    }

    func testAddressShowsHostAndPathWithThePort() {
        XCTAssertEqual(PreviewAddress.display("http://localhost:5173/"), "localhost:5173")
        XCTAssertEqual(PreviewAddress.display("http://localhost:5173"), "localhost:5173")
        XCTAssertEqual(PreviewAddress.display("http://localhost:3000/pond?x=1"), "localhost:3000/pond?x=1")
        XCTAssertEqual(PreviewAddress.display("https://example.com/docs/"), "example.com/docs/")
        XCTAssertEqual(PreviewAddress.display("about:preview"), "about:preview")
        XCTAssertEqual(PreviewAddress.display(nil), "")
        XCTAssertEqual(PreviewAddress.sentence("could not connect to the server"), "Could not connect to the server.")
        XCTAssertEqual(PreviewAddress.sentence("Done."), "Done.")
    }

    func testDevicesKeepTheirShapeAndScaleDownNeverUp() throws {
        XCTAssertEqual(PreviewPane.Device.allCases.map(\.label), ["Fit", "Phone", "Tablet", "Desktop"])
        XCTAssertEqual(PreviewPane.Device.allCases.map(\.menuTitle), ["Fit", "Phone  390 × 844", "Tablet  820 × 1180", "Desktop  1280 × 800"])
        XCTAssertNil(PreviewPane.Device.fit.fitted(in: CGSize(width: 400, height: 500)))
        let big = try XCTUnwrap(PreviewPane.Device.phone.fitted(in: CGSize(width: 1000, height: 1000)))
        XCTAssertEqual(big.size, CGSize(width: 390, height: 844))
        XCTAssertEqual(big.scale, 1)
        let tablet = try XCTUnwrap(PreviewPane.Device.tablet.fitted(in: CGSize(width: 400, height: 500)))
        XCTAssertLessThanOrEqual(tablet.size.width, 400)
        XCTAssertLessThanOrEqual(tablet.size.height, 500)
        XCTAssertEqual(tablet.size.height / tablet.size.width, 1180 / 820, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PreviewPane.Device.desktop.fitted(in: CGSize(width: 400, height: 500))).size.width, 400)
    }

    // MARK: Layout

    private var site: PreviewSite!

    override func setUp() async throws {
        executionTimeAllowance = 240
        site = try await PreviewSite.start()
    }

    override func tearDown() async throws {
        site?.stop()
    }

    enum State: String, CaseIterable {
        case empty, loaded, loading, failed, phone, tablet, desktop, mention
    }

    private func url(_ state: State) -> String? {
        switch state {
        case .empty: nil
        case .loading: "http://localhost:\(site.port)/hold"
        // A port nothing listens on, so the load is refused at once.
        case .failed: "http://localhost:\(site.closedPort)/"
        default: "http://localhost:\(site.port)/"
        }
    }

    private func device(_ state: State) -> PreviewPane.Device {
        switch state {
        case .phone: .phone
        case .tablet: .tablet
        case .desktop: .desktop
        default: .fit
        }
    }

    /// Draw one state at `width` × 560 offscreen: wait for its page to settle, then the probe's
    /// frames and, when `name` is given, a PNG.
    @discardableResult
    private func draw(_ state: State, width: CGFloat, look: NSAppearance.Name = .darkAqua, name: String? = nil) throws -> [String: CGRect] {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.panes.apply(.paneOpened(id: "p1", kind: .preview, title: "Lily pad", cwd: nil, url: url(state)))
        let hub = c.panes
        if state == .mention { hub.mention(("p1"), token: "@button.book", context: nil) }
        let pane = try XCTUnwrap(hub.pane("p1"))
        PreviewProbe.frames = [:]
        let size = CGSize(width: width, height: 560)
        let view = PreviewPane(pane: pane, hub: hub, startDevice: device(state))
            .frame(width: size.width, height: size.height)
            .background(Tokens.sidebar)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let preview = hub.previewHost("p1")
        let deadline = Date().addingTimeInterval(10)
        func settled() -> Bool {
            switch state {
            case .empty: true
            case .loading: preview.loading
            case .failed: preview.loadError != nil
            default: !preview.loading && preview.currentURL != nil
            }
        }
        while Date() < deadline, !settled() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(settled(), "\(state) settled")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        if let name {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("no bitmap"); return [:] }
            host.cacheDisplay(in: host.bounds, to: rep)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
        }
        let frames = PreviewProbe.frames
        window.contentView = nil
        return frames
    }

    private static let tools = ["Back", "Forward", "Reload", "Stop", "Address", "Device size", "Compare with an earlier turn",
                                "Pick an element", "Open in browser", "Open in its own window", "More", "mention", "progress"]

    private func assertOneRow(_ f: [String: CGRect], _ state: State, _ width: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let at = "\(state) at \(width)"
        let bar = try XCTUnwrap(f["bar"], "\(at): a toolbar", file: file, line: line)
        XCTAssertEqual(bar.height, PreviewToolbar.height, accuracy: 0.5, "\(at): one 38 pt row", file: file, line: line)
        XCTAssertEqual(bar.width, width, accuracy: 0.5, "\(at): the row spans the pane", file: file, line: line)
        let parts = Self.tools.compactMap { name in f[name].map { (name, $0) } }
        XCTAssertGreaterThanOrEqual(parts.count, 5, "\(at): \(parts.map(\.0))", file: file, line: line)
        for (name, r) in parts {
            XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(at): \(name) \(r) is inside the row \(bar)", file: file, line: line)
        }
        let row = parts.filter { $0.0 != "progress" }
        for (i, a) in row.enumerated() {
            for b in row.dropFirst(i + 1) {
                XCTAssertFalse(a.1.insetBy(dx: 0.5, dy: 0.5).intersects(b.1.insetBy(dx: 0.5, dy: 0.5)), "\(at): \(a.0) and \(b.0) overlap", file: file, line: line)
            }
        }
        for (name, r) in row where name != "Address" && name != "mention" {
            XCTAssertEqual(r.width, 24, accuracy: 0.5, "\(at): \(name) is a 24 pt plate", file: file, line: line)
            XCTAssertEqual(r.height, 24, accuracy: 0.5, "\(at): \(name) is a 24 pt plate", file: file, line: line)
        }
        let field = try XCTUnwrap(f["Address"], file: file, line: line)
        XCTAssertGreaterThanOrEqual(field.width, 150, "\(at): the address keeps its room", file: file, line: line)
        if width < PreviewToolbar.foldWidth {
            XCTAssertNotNil(f["More"], "\(at): the tools fold into More", file: file, line: line)
            XCTAssertNil(f["Device size"], file: file, line: line)
        } else {
            XCTAssertNil(f["More"], "\(at): the tools are in the row", file: file, line: line)
            XCTAssertNotNil(f["Device size"], file: file, line: line)
            XCTAssertNotNil(f["Pick an element"], file: file, line: line)
            XCTAssertNotNil(f["Open in browser"], file: file, line: line)
        }
    }

    func testOneToolbarRowAtEveryWidth() throws {
        for width: CGFloat in [360, 420, 560] {
            for state in State.allCases {
                try assertOneRow(try draw(state, width: width), state, width)
            }
        }
    }

    func testLoadingShowsStopAndAProgressLineOnTheRowsEdge() throws {
        let f = try draw(.loading, width: 420)
        XCTAssertNotNil(f["Stop"])
        XCTAssertNil(f["Reload"])
        let bar = try XCTUnwrap(f["bar"]), line = try XCTUnwrap(f["progress"])
        XCTAssertEqual(line.height, 2, accuracy: 0.5)
        XCTAssertEqual(line.maxY, bar.maxY, accuracy: 0.5)
    }

    func testEmptyAndFailedAreCentredInTheBody() throws {
        for state in [State.empty, .failed] {
            for width: CGFloat in [360, 560] {
                let f = try draw(state, width: width)
                let stage = try XCTUnwrap(f["stage"]), empty = try XCTUnwrap(f["empty"], "\(state): an empty state")
                XCTAssertEqual(empty.midX, stage.midX, accuracy: 1, "\(state) at \(width): centred across")
                XCTAssertEqual(empty.midY, stage.midY, accuracy: 1, "\(state) at \(width): centred down")
            }
        }
    }

    func testFailedSaysWhatFailedWithRetry() throws {
        try draw(.failed, width: 420)
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        c.panes.apply(.paneOpened(id: "p1", kind: .preview, title: "P", cwd: nil, url: nil))
        let host = c.panes.previewHost("p1")
        host.load("http://localhost:\(site.closedPort)/")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, host.loadError == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertNotNil(host.loadError)
        XCTAssertEqual(host.attemptedURL, "http://localhost:\(site.closedPort)/")
        XCTAssertNil(host.currentURL, "a refused first load commits nothing")
        let pane = PreviewPane(pane: try XCTUnwrap(c.panes.pane("p1")), hub: c.panes)
        XCTAssertEqual(pane.bodyState, .failed(host.loadError!))
    }

    func testDevicesTakeTheirShapeInsideTheBody() throws {
        for (state, ratio) in [(State.phone, 844.0 / 390), (.tablet, 1180.0 / 820), (.desktop, 800.0 / 1280)] {
            let f = try draw(state, width: 420)
            let stage = try XCTUnwrap(f["stage"]), frame = try XCTUnwrap(f["frame"])
            XCTAssertTrue(stage.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(state): inside the body")
            XCTAssertEqual(frame.height / frame.width, ratio, accuracy: 0.02, "\(state): the device's shape \(frame)")
        }
        let fit = try draw(.loaded, width: 420)
        XCTAssertEqual(try XCTUnwrap(fit["frame"]).width, try XCTUnwrap(fit["stage"]).width, accuracy: 0.5, "Fit fills the body")
    }

    /// The checked-in pictures, light and dark.
    func testRenderPreviewStates() throws {
        let shots: [(String, State, CGFloat)] = [
            ("empty", .empty, 420), ("loaded", .loaded, 420), ("narrow", .loaded, 360), ("loading", .loading, 420),
            ("failed", .failed, 420), ("phone", .phone, 420), ("tablet", .tablet, 420), ("desktop", .desktop, 420),
        ]
        for (look, theme) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for (name, state, width) in shots {
                try draw(state, width: width, look: look, name: "preview-\(name)-mac-\(theme)")
            }
        }
        print("snapshots: \(outDir.path)")
    }
}

/// A dev server for the tests: `/` is the web's parity page (apps/web/parity/sample), `/hold`
/// never answers, so a load stays in progress.
final class PreviewSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "preview-site")
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0
    /// A port that was free a moment ago and has nothing listening on it now.
    let closedPort: UInt16 = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }()
    private let page: Data

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "../web/parity/sample/index.html").standardized
        page = try Data(contentsOf: url)
    }

    static func start() async throws -> PreviewSite {
        let s = try PreviewSite()
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        for _ in 0..<250 {
            if let p = s.listener.port?.rawValue, p != 0 { s.port = p; return s }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PreviewSite", code: 1)
    }

    func stop() {
        queue.sync { held.forEach { $0.cancel() }; held = [] }
        listener.cancel()
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if head.hasPrefix("GET /hold") { self.held.append(c); return }
            let body = head.hasPrefix("GET / ") ? self.page : Data()
            let status = body.isEmpty ? "404 Not Found" : "200 OK"
            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

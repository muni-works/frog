import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Frog

/// Visualize's card on the Mac: a recorded widget (docs/design/visuals/fixtures) loads in the
/// locked-down web view, runs its script, reports its height, and draws. The render lands in
/// `$FROG_SNAPSHOT_DIR` (else a temp folder) as `widget-<name>.png`.
@MainActor
final class WidgetViewTests: XCTestCase {
    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// The first widget in a fixture session log, decoded as the app decodes items.
    private func widget(_ name: String) throws -> VisualWidget {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let log = try String(contentsOf: root.appending(path: "docs/design/visuals/fixtures/\(name).jsonl"), encoding: .utf8)
        for line in log.split(separator: "\n") {
            guard line.contains("\"widget\""),
                  let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let env = obj["env"] as? [String: Any], let item = env["item"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: item)
            if case .toolCall(let r) = try JSONDecoder().decode(Item.self, from: data), let w = r.widget { return w }
        }
        throw XCTSkip("no widget in \(name).jsonl")
    }

    func testRecordedWidgetsRenderAndReportHeight() async throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for name in ["casimir", "implicit"] {
            let w = try widget(name)
            var reported: CGFloat = 0
            let height = Binding<CGFloat>(get: { reported }, set: { reported = $0 })
            let host = WidgetWebView.Host(WidgetWebView(html: w.html, height: height, onPrompt: { _ in }))
            let web = WidgetWebView.makeWebView(html: w.html, host: host)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.07, alpha: 1)
            web.frame = window.contentView!.bounds
            window.contentView!.addSubview(web)
            window.orderBack(nil)
            for _ in 0..<80 where reported == 0 { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertGreaterThan(reported, 200, "\(name): the widget never reported its height")
            try await Task.sleep(for: .milliseconds(1200))
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: 720, height: min(max(reported, 200), 900))
            let image = try await web.takeSnapshot(configuration: config)
            let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
            try rep?.representation(using: .png, properties: [:])?.write(to: outDir.appending(path: "widget-\(name).png"))
            window.orderOut(nil)
        }
    }

    func testPromptGateSpacesAndCaps() {
        var gate = PromptGate()
        let t0 = Date()
        XCTAssertTrue(gate.allow(t0))
        XCTAssertFalse(gate.allow(t0.addingTimeInterval(1)))
        XCTAssertTrue(gate.allow(t0.addingTimeInterval(5)))
        XCTAssertTrue(gate.allow(t0.addingTimeInterval(10)))
        XCTAssertFalse(gate.allow(t0.addingTimeInterval(20)))
        XCTAssertTrue(gate.allow(t0.addingTimeInterval(61)))
    }

    func testTitlesReadAsWords() {
        XCTAssertEqual(VisualWidget(title: "casimir_mode_filter", code: "", html: "").displayTitle, "Casimir mode filter")
        XCTAssertEqual(VisualWidget(title: "Coil field", code: "", html: "").displayTitle, "Coil field")
    }
}

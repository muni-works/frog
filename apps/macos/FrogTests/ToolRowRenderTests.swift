import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Cam's report, checked against pixels: a `SendMessage` row took two clicks and said its label
/// twice. This renders the row (collapsed, then opened) and reads the text back out of the
/// image — the only way a test can see what actually reached the screen, since a hosted SwiftUI
/// view exposes no text to the accessibility tree (checked: `NSHostingView(rootView: Text("…"))`
/// reads back empty; Vision OCR fails in a sandboxed test). Uses `tesseract` when it's installed
/// and skips otherwise, so CI without it isn't red about the readback.
///
/// Writes `$TMPDIR/frog-snapshots/sendmessage-row-<state>.png` for design review either way.
@MainActor
final class ToolRowRenderTests: XCTestCase {
    private func item() -> ItemState {
        var item = ItemState(id: "t1", kind: .tool(name: "SendMessage", arg: "ops"))
        item.done = true
        item.result = Item.ToolResult(
            name: "SendMessage", arg: "ops", input: nil, outcome: .ok,
            output: "Sent to ops (20261112-175150-6a2c); delivered (turn started). It reads the message at its next turn boundary.",
            display: nil)
        return item
    }

    private var outDir: URL {
        FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// The row rendered to a PNG, as the screen shows it.
    private func render(_ view: some View, size: CGSize, to name: String) throws -> URL {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, alignment: .leading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appending(path: "\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// The text tesseract can read in a PNG, or nil when it isn't installed.
    private func read(_ url: URL) -> [String]? {
        let bin = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [url.path, "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The whole point: the label appears once, collapsed and open, and the sentence is on
    /// screen without a second click.
    func testTheLabelAppearsOnceCollapsedAndOpen() throws {
        let c = Conversation(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog"), link: nil, replay: false, session: "row")
        let group = ActivityGroup(steps: [item()])
        let size = CGSize(width: 900, height: 200)
        try withTesseract {
            for (state, view) in [("collapsed", AnyView(ActivityLine(group: group, conversation: c))),
                                  ("open", AnyView(ActivityLine(group: group, conversation: c, expanded: true)))] {
                let png = try render(view, size: size, to: "sendmessage-row-\(state)")
                let read = try XCTUnwrap(read(png), "tesseract gave no output")
                let said = read.filter { $0.localizedCaseInsensitiveContains("SendMessage") }
                XCTAssertEqual(said.count, 1, "[\(state)] the label must appear once; read back: \(read)")
                let payload = read.filter { $0.localizedCaseInsensitiveContains("delivered") }
                XCTAssertFalse(payload.isEmpty, "[\(state)] the result must be visible; read back: \(read)")
            }
        }
    }

    /// Runs `body` when OCR is available; skips the test (not failure) when it isn't.
    private func withTesseract(_ body: () throws -> Void) throws {
        let bin = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(bin == nil, "tesseract isn't installed: the render readback can't run here")
        try body()
    }
}

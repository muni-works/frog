import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Cam's report, checked against pixels: a row took two clicks to reach its payload and said
/// its label twice. This renders rows (collapsed, then opened) and reads the text back out of
/// the image — the only way a test can see what actually reached the screen, since a hosted
/// SwiftUI view exposes no text to the accessibility tree (checked: `NSHostingView(rootView:
/// Text("…"))` reads back empty; Vision OCR fails in a sandboxed test). Uses `tesseract` when
/// it's installed and skips otherwise, so CI without it isn't red about the readback.
///
/// Writes `$TMPDIR/frog-snapshots/<row>-<state>.png` for design review either way.
@MainActor
final class ToolRowRenderTests: XCTestCase {
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

    /// A payload tool: its line names it, and opening it shows the file. Collapsed, the file
    /// stays closed — a payload is exactly what the chevron is for.
    ///
    /// This drives a `Read`, not the `SendMessage` from Cam's report, because it is the row
    /// where a duplicate label can still *appear*: since #339 a tool the switch doesn't name
    /// has no verb at all — its result is the line — so "SendMessage" is drawn nowhere and a
    /// search for it proves nothing (this test failed on main for exactly that, 2026-11-14).
    func testTheLabelAppearsOnceAndThePayloadOpens() throws {
        var readItem = ItemState(id: "t1", kind: .tool(name: "Read", arg: "src/retry.rs"))
        readItem.done = true
        // No engine summary: "Read 2 lines" would itself contain the word "Read" and read as
        // a second label to OCR.
        readItem.result = Item.ToolResult(
            name: "Read", arg: "src/retry.rs", input: nil, outcome: .ok,
            output: "let retries = 3\nlet backoff = 250\n", display: nil)
        let c = Conversation(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog"), link: nil, replay: false, session: "row")
        let group = ActivityGroup(steps: [readItem])
        let size = CGSize(width: 900, height: 200)
        let label = try XCTUnwrap(VerbLine.of(readItem)?.verb)
        XCTAssertEqual(label, "Read", "the premise: this row does print a label")
        try withTesseract {
            // Collapsed: the line says what it read, exactly once, and nothing is open.
            let closed = try XCTUnwrap(read(try render(
                AnyView(ActivityLine(group: group, conversation: c)),
                size: size, to: "read-row-collapsed")))
            let closedLabels = closed.filter { $0.localizedCaseInsensitiveContains(label) }
            XCTAssertEqual(closedLabels.count, 1,
                           "[collapsed] \"\(label)\" must appear once; read back: \(closed)")
            let closedPayload = closed.filter { $0.localizedCaseInsensitiveContains("retries") }
            XCTAssertTrue(closedPayload.isEmpty,
                          "[collapsed] a payload stays closed; read back: \(closed)")

            // Open: the line still appears once — no inner row repeating it — and the file shows.
            let open = try XCTUnwrap(read(try render(
                AnyView(ActivityLine(group: group, conversation: c, expanded: true)),
                size: size, to: "read-row-open")))
            let openLabels = open.filter { $0.localizedCaseInsensitiveContains(label) }
            XCTAssertEqual(openLabels.count, 1,
                           "[open] \"\(label)\" must appear once — a repeated row is the bug; read back: \(open)")
            let openPayload = open.filter { $0.localizedCaseInsensitiveContains("retries") }
            XCTAssertFalse(openPayload.isEmpty, "[open] the payload must be visible; read back: \(open)")
        }
    }

    /// And Cam's own row, whose whole result is one sentence: it is on screen with no click.
    func testAShortResultIsVisibleWithoutAClick() throws {
        var item = ItemState(id: "t2", kind: .tool(name: "SendMessage", arg: "ops"))
        item.done = true
        item.result = Item.ToolResult(
            name: "SendMessage", arg: "ops", input: nil, outcome: .ok,
            output: "Sent to ops (20261112-175150-6a2c); delivered (turn started). It reads the message at its next turn boundary.",
            display: nil)
        let c = Conversation(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog"), link: nil, replay: false, session: "row")
        let group = ActivityGroup(steps: [item])
        let size = CGSize(width: 900, height: 200)
        try withTesseract {
            for (state, view) in [("collapsed", AnyView(ActivityLine(group: group, conversation: c))),
                                  ("open", AnyView(ActivityLine(group: group, conversation: c, expanded: true)))] {
                let png = try render(view, size: size, to: "sendmessage-row-\(state)")
                let read = try XCTUnwrap(read(png), "tesseract gave no output")
                let said = read.filter { $0.localizedCaseInsensitiveContains("SendMessage") }
                // A finished row drops its verb (#339), so the label may not show at all; where
                // it does, it shows once.
                XCTAssertLessThanOrEqual(said.count, 1, "[\(state)] the label must not repeat; read back: \(read)")
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

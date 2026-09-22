import AppKit
import SwiftUI
import XCTest
@testable import Kiln

/// Renders fixture sessions through the real views into PNGs, for design review without a model
/// or a screen: `$TMPDIR/kiln-snapshots/<fixture>-<state>.png`.
@MainActor
final class SnapshotTests: XCTestCase {
    private var outDir: URL {
        FileManager.default.temporaryDirectory.appending(path: "kiln-snapshots")
    }

    private func fixtures() throws -> [URL] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Durable events from a session log, in order.
    private func events(_ url: URL) throws -> [Envelope] {
        struct Record: Decodable {
            let type: String
            let env: Envelope?
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try JSONDecoder.kiln.decode(Record.self, from: Data($0.utf8)).env }
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (scroll anchors, lazy stacks) before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    private func transcript(_ c: Conversation) -> some View {
        TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .background(Color(nsColor: .windowBackgroundColor))
    }

    func testRenderFixtures() throws {
        for url in try fixtures() {
            let name = url.deletingPathExtension().lastPathComponent
            let all = try events(url)
            XCTAssertFalse(all.isEmpty, name)

            // Finished: the outcome card.
            let done = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
            all.forEach(done.ingest)
            try render(transcript(done), size: CGSize(width: 900, height: 1000), to: "\(name)-done")
            try render(
                ChangesInspector(conversation: done).background(Color(nsColor: .windowBackgroundColor)),
                size: CGSize(width: 420, height: 800), to: "\(name)-changes")

            // Mid-turn: everything up to the second-to-last tool call, so the work group is live.
            let toolStarts = all.indices.filter {
                if case .itemStarted(_, .toolCall) = all[$0].event { true } else { false }
            }
            if let cut = toolStarts.dropLast().last {
                let live = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
                all[...cut].forEach(live.ingest)
                try render(transcript(live), size: CGSize(width: 900, height: 800), to: "\(name)-live")
            }
        }
        try render(
            CommandPalette(commands: [
                PaletteCommand(id: "1", title: "New Session", subtitle: "⇧⌘N", symbol: "square.and.pencil") {},
                PaletteCommand(id: "2", title: "Show Changes", subtitle: "⌥⌘0", symbol: "plusminus") {},
                PaletteCommand(id: "3", title: "Mode: Accept Edits", symbol: "pencil.and.outline") {},
                PaletteCommand(id: "4", title: "Model: ollama/qwen3:4b", subtitle: "native tools · medium tier", symbol: "cpu") {},
                PaletteCommand(id: "5", title: "Rename get_usr to get_user everywhere", subtitle: "ollama/qwen3:4b", symbol: "bubble.left") {},
            ], dismiss: {})
            .padding(40)
            .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 660, height: 420), to: "palette")
        print("snapshots: \(outDir.path)")
    }
}

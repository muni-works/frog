import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The inspector card (the right sidebar) to the unified spec, in dark and light: with changes,
/// with one file opened, and empty. `$FROG_SNAPSHOT_DIR` or `$TMPDIR/frog-snapshots`,
/// `inspector-<state>-<look>.png`, for review beside the web's inspector.
@MainActor
final class InspectorSnapshotTests: XCTestCase {
    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// A fixture session. `alsoAt` repeats its first edit under other paths (a path ending in
    /// "+" is a new file), since no recorded fixture touches more than one file.
    private func fixture(_ name: String, alsoAt paths: [String] = []) throws -> Conversation {
        struct Record: Decodable {
            let type: String
            let env: Envelope?
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/\(name).jsonl")
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        if let i = lines.firstIndex(where: { $0.contains(#""event":"item_started""#) && $0.contains(#""name":"Edit""#) }),
           let j = lines.firstIndex(where: { $0.contains(#""event":"item_completed""#) && $0.contains(#""diff":{"path""#) }) {
            let copies = paths.enumerated().flatMap { n, path in
                let created = path.hasSuffix("+"), file = created ? String(path.dropLast()) : path
                return [lines[i], lines[j]].map {
                    $0.replacingOccurrences(of: "call_dtx9d5aa", with: "call_copy\(n)")
                        .replacingOccurrences(of: "fizzbuzz.py", with: file)
                        .replacingOccurrences(of: #""created":false"#, with: #""created":\#(created)"#)
                }
            }
            lines.insert(contentsOf: copies, at: j + 1)
        }
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        try lines.compactMap { try JSONDecoder.frog.decode(Record.self, from: Data($0.utf8)).env }.forEach(c.ingest)
        return c
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    /// The inspector as the window draws it: a flush column with its hairline, beside a strip
    /// of the page.
    private func card(_ c: Conversation, git: ((String) -> Void)? = { _ in }) -> some View {
        PaneArea(conversation: c, height: 584, width: .constant(PaneArea.defaultWidth), collapse: {},
                 folder: URL(fileURLWithPath: "/tmp/demo"), git: git)
            .flushColumn(leading: true, underTitleBar: false)
            .padding(.leading, 24)
            .background(Tokens.canvas)
    }

    func testRenderInspector() throws {
        let many = try fixture("fix-python-test", alsoAt: [
            "tests/test_fizzbuzz.py", "src/frog/app/components/inspector/ChangesHeader.swift", "docs/notes.md+",
        ])
        let one = try fixture("fix-python-test")
        let empty = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        XCTAssertEqual(many.sessionChanges.count, 4)
        XCTAssertEqual(one.sessionChanges.count, 1)
        XCTAssertTrue(empty.sessionChanges.isEmpty)
        let size = CGSize(width: PaneArea.defaultWidth + 24, height: 584)
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(card(many), size: size, to: "inspector-changes-\(name)", appearance: look)
            try render(card(one), size: size, to: "inspector-one-file-\(name)", appearance: look)
            try render(card(empty), size: size, to: "inspector-empty-\(name)", appearance: look)
        }
        print("snapshots: \(outDir.path)")
    }

    /// The strip is always Changes, Terminal, Preview in that order, whatever opened first;
    /// further panes follow as they opened.
    func testStripOrder() {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        let area = { PaneArea(conversation: c, height: 400, width: .constant(420)) }
        XCTAssertEqual(area().slots, [.tab(.changes), .open(.terminal), .open(.preview)])
        c.panes.apply(.paneOpened(id: "p1", kind: .preview, title: "Demo", cwd: nil, url: nil))
        c.panes.apply(.paneOpened(id: "t1", kind: .terminal, title: "zsh", cwd: "/tmp/demo", url: nil))
        c.panes.apply(.paneOpened(id: "t2", kind: .terminal, title: "zsh", cwd: "/tmp/demo", url: nil))
        XCTAssertEqual(area().slots, [.tab(.changes), .tab(.pane("t1")), .tab(.pane("p1")), .tab(.pane("t2"))])
    }

    /// Width: 420 by default, dragged between 360 and 560.
    func testWidthBounds() {
        XCTAssertEqual(PaneArea.defaultWidth, 420)
        XCTAssertEqual(PaneArea.minWidth, 360)
        XCTAssertEqual(PaneArea.maxWidth, 560)
        let saved = UserDefaults.standard.object(forKey: PaneArea.widthKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: PaneArea.widthKey) } else { UserDefaults.standard.removeObject(forKey: PaneArea.widthKey) } }
        UserDefaults.standard.removeObject(forKey: PaneArea.widthKey)
        XCTAssertEqual(PaneArea.savedWidth, 420)
        UserDefaults.standard.set(900.0, forKey: PaneArea.widthKey)
        XCTAssertEqual(PaneArea.savedWidth, 560)
        UserDefaults.standard.set(100.0, forKey: PaneArea.widthKey)
        XCTAssertEqual(PaneArea.savedWidth, 360)
    }
}

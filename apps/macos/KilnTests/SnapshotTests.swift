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
                ChangesInspector(conversation: done, maxHeight: 800).background(Color(nsColor: .windowBackgroundColor)),
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

extension SnapshotTests {
    /// A subagent mid-run (steps, thinking, the report being written) and finished.
    func testRenderSubagent() throws {
        func sub(_ inner: String) -> String {
            #"{"seq":0,"session":"s","created":0,"event":"subagent","item":"t1","inner":\#(inner)}"#
        }
        let lines = [
            #"{"seq":1,"session":"s","created":0,"event":"turn_started","turn":1,"input":"Where are MCP descriptions quarantined?"}"#,
            #"{"seq":2,"session":"s","created":0,"event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Task","arg":"Find MCP quarantine"}}"#,
            sub(#"{"event":"item_started","id":"a","kind":{"type":"tool_call","name":"Grep","arg":"quarantine|suspicious"}}"#),
            sub(#"{"event":"item_completed","id":"a","item":{"type":"tool_call","name":"Grep","arg":"quarantine|suspicious","input":{},"outcome":"ok","output":"","display":null}}"#),
            sub(#"{"event":"item_started","id":"b","kind":{"type":"tool_call","name":"Read","arg":"crates/kiln-engine/src/mcp.rs"}}"#),
            sub(#"{"event":"item_completed","id":"b","item":{"type":"tool_call","name":"Read","arg":"crates/kiln-engine/src/mcp.rs","input":{},"outcome":"ok","output":"","display":null}}"#),
            sub(#"{"event":"item_started","id":"c","kind":{"type":"tool_call","name":"Grep","arg":"fn status"}}"#),
            sub(#"{"event":"status","model":"tang/Qwen/Qwen3-4B","mode":"default","cwd":"/tmp","messages":4,"context_tokens":5100,"context_window":32768,"tool_mode":"native","tier":"medium","tokens_per_sec":71.0,"todos":[]}"#),
            sub(#"{"event":"item_completed","id":"c","item":{"type":"tool_call","name":"Grep","arg":"fn status","input":{},"outcome":"ok","output":"","display":null}}"#),
            sub(#"{"event":"item_started","id":"d","kind":{"type":"message"}}"#),
            sub(#"{"event":"item_delta","id":"d","delta":{"type":"text","text":"Suspicious descriptions are caught by `suspicious()` in `crates/kiln-engine/src/mcp.rs:836`, which checks"}}"#),
        ]
        let events = try lines.map { try JSONDecoder.kiln.decode(Envelope.self, from: Data($0.utf8)) }
        let live = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        events.forEach(live.ingest)
        try render(transcript(live), size: CGSize(width: 900, height: 560), to: "subagent-live")

        let end = [
            #"{"seq":3,"session":"s","created":0,"event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"Find MCP quarantine","input":{},"outcome":"ok","output":"Suspicious descriptions are caught by `suspicious()` in `crates/kiln-engine/src/mcp.rs:836`, which checks each tool's description and schema against injection patterns and hidden Unicode. `Hub::status` and `Hub::catalog` leave quarantined tools out unless the server has `trust = true`.","display":null}}"#,
            #"{"seq":4,"session":"s","created":0,"event":"item_started","id":"m","kind":{"type":"message"}}"#,
            #"{"seq":5,"session":"s","created":0,"event":"item_completed","id":"m","item":{"type":"message","text":"In `mcp.rs`, `suspicious()` (line 836)."}}"#,
        ]
        try end.map { try JSONDecoder.kiln.decode(Envelope.self, from: Data($0.utf8)) }.forEach(live.ingest)
        try render(transcript(live), size: CGSize(width: 900, height: 560), to: "subagent-done")
        print("snapshots: \(outDir.path)")
    }

    /// Diagram cards, in dark and light: the model's diagrams from recent sessions (when
    /// present) and one laid out from Mermaid by the engine.
    func testRenderDiagrams() async throws {
        var diagrams: [(String, Diagram)] = []
        let sessions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/kiln/sessions")
        for id in ["20260923-092701-d2c9", "20260923-091914-5a1c"] {
            let url = sessions.appending(path: "\(id).jsonl")
            guard let all = try? events(url) else { continue }
            for env in all {
                if case .itemCompleted(_, .toolCall(let r)) = env.event, let d = r.diagram {
                    diagrams.append(("diagram-\(id)", d))
                }
            }
        }
        let mermaid = """
        flowchart TD
          subgraph clients [Clients]
            app([Mac app])
            tui[Terminal UI]
          end
          subgraph engine [kiln-engine]
            loop[Agent loop] --> tools[Tools]
            loop -.->|append| log[(Session log)]
          end
          app -->|ops| loop
          tui -->|ops| loop
          loop ==>|chat| model[/Model provider/]
          model -->|stream| loop
          tools --> check{Needs permission?}
        """
        if let d = await Diagram.fromMermaid(mermaid, cwd: URL(fileURLWithPath: "/")) {
            diagrams.append(("diagram-mermaid", d))
        } else {
            XCTFail("kiln --mermaid failed")
        }
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "crates/kiln-engine")
        if let d = await Diagram.codeMap(in: engine) {
            diagrams.append(("diagram-codemap", d))
            let full = DiagramCanvas(diagram: d)
                .environment(\.diagramStatic, true)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(full, size: CGSize(width: (d.layout?.width ?? 400) + 20, height: (d.layout?.height ?? 300) + 20), to: "codemap-full")
        } else {
            XCTFail("kiln --map failed")
        }
        XCTAssertFalse(diagrams.isEmpty)
        for (name, d) in diagrams {
            for dark in [true, false] {
                let view = DiagramCard(diagram: d)
                    .environment(\.diagramStatic, true)
                    .padding(20)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let w = min(1400, (d.layout?.width ?? 400) + 60)
                let h = min(1400, (d.layout?.height ?? 300) + 160)
                try render(view, size: CGSize(width: w, height: h), to: name + (dark ? "" : "-light"))
            }
        }
    }
}


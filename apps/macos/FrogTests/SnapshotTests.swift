import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Renders fixture sessions through the real views into PNGs, for design review without a model
/// or a screen: `$TMPDIR/frog-snapshots/<fixture>-<state>.png`.
@MainActor
final class SnapshotTests: XCTestCase {
    /// `$FROG_SNAPSHOT_DIR` when set (pass it as `TEST_RUNNER_FROG_SNAPSHOT_DIR` to xcodebuild):
    /// the shared temp folder is written by every worktree's test run, so two sessions rendering
    /// at once overwrite each other's PNGs.
    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
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
            .compactMap { try JSONDecoder.frog.decode(Record.self, from: Data($0.utf8)).env }
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, settle: TimeInterval = 0.4, appearance: NSAppearance.Name = .darkAqua) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (scroll anchors, lazy stacks) before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
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

    /// The popovers behind a turn's cost and energy hints, for a hosted model's turn.
    func testRenderTurnCostCards() throws {
        let usage = try JSONDecoder.frog.decode(TurnUsage.self, from: Data(#"{"input_tokens":12400,"output_tokens":380,"model_calls":2,"model":"vercel/anthropic/claude-opus-5.5-fast","energy":{"local_wh":0.021,"remote_wh":2.96,"idle_w":11.6}}"#.utf8))
        let energy = try XCTUnwrap(usage.energy)
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(EnergyCard(energy: energy, usage: usage).fixedSize().frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 290, height: 520), to: "energy-card-\(name)", appearance: look)
            try render(PriceCard(cost: 0.214, usage: usage, listed: .init(spec: usage.model ?? "", input: 15, output: 75)).fixedSize().frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 290, height: 460), to: "price-card-\(name)", appearance: look)
        }
    }

    /// Settings › Energy with a day of turns on three models, from a throwaway defaults suite.
    func testRenderEnergySettings() throws {
        let suite = "frog-snapshot-energy"
        UserDefaults().removePersistentDomain(forName: suite)
        let stats = ModelStats(defaults: UserDefaults(suiteName: suite)!)
        let turn = { (model: String, local: Double, remote: Double?, basis: String?) throws -> TurnUsage in
            var json = #"{"input_tokens":9000,"output_tokens":600,"model_calls":3,"model":"\#(model)","energy":{"local_wh":\#(local)"#
            if let remote { json += #","remote_wh":\#(remote)"# }
            if let basis { json += #","remote_basis":"\#(basis)","remote_source":"https://huggingface.co/deepseek-ai/DeepSeek-V3""# }
            json += "}}"
            return try JSONDecoder.frog.decode(TurnUsage.self, from: Data(json.utf8))
        }
        for h in stride(from: 0.0, to: 20, by: 1) {
            let at = Date.now.addingTimeInterval(-h * 3600)
            if Int(h) % 3 != 2 { stats.record(try turn("tang/mlx-community/Qwen3-8B-4bit", 0.4 + 0.05 * h.truncatingRemainder(dividingBy: 5), nil, nil), model: nil, at: at) }
            if Int(h) % 4 == 0 { stats.record(try turn("openrouter/deepseek/deepseek-chat-v3", 0.03, 0.9, "DeepSeek-V3: 37.0B active parameters, scaled from Epoch AI's GPT-4o estimate"), model: nil, at: at) }
            if Int(h) % 6 == 1 { stats.record(try turn("apple/on-device", 0.05, nil, nil), model: nil, at: at) }
        }
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(EnergySettings(stats: stats).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 620, height: 900), to: "energy-settings-\(name)", settle: 0.8, appearance: look)
        }
        UserDefaults().removePersistentDomain(forName: suite)
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

    /// Generated images remain visible in a finished turn, and decode for the lightbox.
    func testRenderImageGeneration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/image-generation.jsonl")
        let conversation = Conversation(preview: URL(fileURLWithPath: "/tmp/frog-image-test"))
        try events(url).forEach(conversation.ingest)
        let turn = try XCTUnwrap(conversation.turns.first)
        let visual = TurnFlow(turn.items).segments.compactMap { segment -> ItemState? in
            if case .visual(let item) = segment { item } else { nil }
        }
        XCTAssertEqual(visual.count, 1, "generated images must not collapse into activity history")
        let result = try XCTUnwrap(visual.first?.result)
        XCTAssertEqual(result.name, "Image")
        let images = try XCTUnwrap(result.images)
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy { $0.image?.size == CGSize(width: 320, height: 192) })
        let lightbox = Lightbox()
        lightbox.show(images, at: 0)
        XCTAssertTrue(lightbox.isOpen)
        lightbox.step(1)
        XCTAssertEqual(lightbox.index, 1)
        lightbox.step(1)
        XCTAssertEqual(lightbox.index, 0)
        lightbox.close()
        XCTAssertFalse(lightbox.isOpen)
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(transcript(conversation), size: CGSize(width: 900, height: 650),
                       to: "image-generation-\(name)", appearance: look)
        }
    }

    /// A captured page stays visible; comparison output remains available after completion.
    func testRenderVisualLoop() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/visual-loop.jsonl")
        let conversation = Conversation(preview: URL(fileURLWithPath: "/tmp/frog-visual-test"))
        try events(url).forEach(conversation.ingest)
        let turn = try XCTUnwrap(conversation.turns.first)
        let captures = turn.items.filter { $0.result?.name == "Screenshot" }
        let capture = try XCTUnwrap(captures.first?.result)
        XCTAssertEqual(capture.outcome, .ok)
        XCTAssertEqual(capture.images?.first?.image?.size, CGSize(width: 320, height: 192))
        let comparisons = turn.items.compactMap(\.result).filter { $0.name == "Compare" }
        XCTAssertEqual(comparisons.count, 2)
        XCTAssertTrue(comparisons.first?.output.contains("matched") ?? false)
        XCTAssertEqual(comparisons.last?.outcome, .error)
        let visuals = TurnFlow(turn.items).segments.filter { if case .visual = $0 { true } else { false } }
        XCTAssertEqual(visuals.count, 1)
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            try render(transcript(conversation), size: CGSize(width: 900, height: 650),
                       to: "visual-loop-\(name)", appearance: look)
        }
    }

    /// Opening a conversation that's slow to load: "Loading session…" (after a beat), never the
    /// new-conversation page.
    func testRenderReopening() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"), reopened: true)
        try render(transcript(c), size: CGSize(width: 900, height: 500), to: "reopening", settle: 0.6)
    }
}

extension SnapshotTests {
    /// Every frog mood, and the frog on its lily pad.
    /// Every model label size in every state and place, for docs/models.md review:
    /// `model-labels.png`.
    func testRenderModelLabels() throws {
        func m(_ name: String, _ place: ModelIdentity.Place, _ state: ModelIdentity.State,
               _ abilities: ModelIdentity.Abilities = [.usesTools]) -> ModelIdentity {
            ModelIdentity(spec: "x/\(name)", name: name, variant: nil, place: place, abilities: abilities,
                          paramsB: nil, context: nil, price: nil, state: state, repo: "r/\(name)", downloadGB: 4.6)
        }
        let models = [
            m("Qwen3 8B", .mac, .ready),
            m("Apple Intelligence", .apple, .ready, []),
            m("Qwen3 8B", .server("mew (RTX 3090)"), .ready),
            m("Claude Sonnet 5", .cloud("Anthropic"), .ready, [.usesTools, .seesImages, .reasons]),
            m("Gemma 3 4B", .mac, .notDownloaded(gb: 3.4), [.seesImages]),
            m("Qwen3 8B", .mac, .downloading(fraction: 0.45)),
            m("Qwen3 8B", .mac, .downloadFailed("offline")),
            m("GPT-5", .cloud("OpenAI"), .needsKey(provider: "OpenAI")),
            m("Qwen3 Coder 30B", .mac, .wontFit(needsGB: 32, hasGB: 24)),
            m("Claude Opus 5.5", .cloud("Anthropic"), .notAllowed(project: "kiln"), [.reasons]),
        ]
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                HStack(spacing: 24) {
                    ModelLabel(model: model).frame(width: 190, alignment: .leading)
                    HStack {
                        ModelLabel(model: model, size: .row, detail: "38 words/s")
                        Spacer()
                        ModelStateAction(model: model)
                    }
                    .frame(width: 360, alignment: .leading)
                    ModelLabel(model: model, size: .caption).frame(width: 300, alignment: .leading)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        try render(sheet, size: CGSize(width: 960, height: 580), to: "model-labels")
    }

    /// The first-run choice, wide (side by side) and narrow (stacked): `first-run-*.png`.
    func testRenderFirstRun() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        for (name, width) in [("wide", 640.0), ("narrow", 340.0)] {
            try render(
                EmptyTranscript(conversation: c)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor)),
                size: CGSize(width: width, height: name == "wide" ? 300 : 520), to: "first-run-\(name)")
        }
    }

    /// The model picker over a real folder's model list: `model-menu.png`.
    func testRenderModelMenu() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = Workspace(folder: dir, fresh: true)
        defer { w.stop() }
        await w.reloadModels()
        await ProviderStore.shared.load()
        try render(
            ModelMenu(workspace: w, current: w.models.first?.spec, pick: { _ in }, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
                // The canvas's margins, as a popover from the composer inherits them.
                .contentMargins(.leading, 200, for: .scrollContent),
            size: CGSize(width: 340, height: 520), to: "model-menu")
    }

    /// Settings > Models as it is on this Mac: `settings-models.png`.
    func testRenderModelSettings() async throws {
        await ProviderStore.shared.load()
        try render(
            ModelSettings().background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 640, height: 1500), to: "settings-models", settle: 5)
    }

    /// frog cloud's card signed out, with a Keychain key and with FROG_API_KEY: `frog-cloud-card.png`.
    func testRenderFrogCloudCard() throws {
        func p(_ key: String?) -> ProviderInfo {
            ProviderInfo(id: "cloud", name: "frog cloud", kind: "openai", baseUrl: "https://api.frog.toys/v1",
                         local: false, custom: false, key: key, keyUrl: "https://api.frog.toys/beta",
                         connected: key != nil, rank: 2, pinned: true)
        }
        let cards = Form {
            Section("Signed out") { FrogCloudCard(provider: p(nil)) { _ in } }
            Section("Keychain") { FrogCloudCard(provider: p("keychain")) { _ in } }
            Section("Environment") { FrogCloudCard(provider: p("env")) { _ in } }
        }
        .formStyle(.grouped)
        .background(Color(nsColor: .windowBackgroundColor))
        try render(cards, size: CGSize(width: 640, height: 360), to: "frog-cloud-card")
    }

    /// A new chat's empty page on this Mac: recent projects, what frog found. `new-chat.png`.
    func testRenderNewChat() throws {
        let c = Conversation(preview: Frog.chatFolder)
        try render(
            EmptyTranscript(conversation: c)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 820, height: 460), to: "new-chat", settle: 4)
    }

    /// A new conversation in this repository: what frog read, where to start. `project-greeting.png`.
    func testRenderProjectGreeting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let c = Conversation(preview: root)
        try render(
            EmptyTranscript(conversation: c)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 820, height: 420), to: "project-greeting", settle: 4)
    }

    /// A prompt's and an answer's actions as they show on hover: `message-actions.png`.
    func testRenderMessageActions() throws {
        var turn = TurnState(number: 3, input: "what directory is this", startedAt: Date().addingTimeInterval(-600))
        turn.end = .complete
        let usage = TurnUsage(contextTokens: nil, inputTokens: 900, outputTokens: 40, modelCalls: 2, tokensPerSec: 24, model: "apple/on-device")
        let sheet = VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                UserPrompt(text: turn.input)
                PromptActions(turn: turn, visible: true, copy: {}, rewind: {}, fork: {})
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Text("The current working directory is /Users/cam/Developer/kiln.")
            EndView(reason: .complete, usage: usage, answer: "The current working directory…", hovering: true)
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        try render(sheet, size: CGSize(width: 760, height: 220), to: "message-actions")
        try render(
            HStack { Spacer(); ActionTooltip(text: "Fork a new conversation from here") }
                .padding(24).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 420, height: 80), to: "action-tooltip")
    }

    func testRenderFrogFaces() throws {
        let moods: [(String, FrogMood)] = [
            ("idle", .idle), ("reading", .reading), ("thinking", .thinking), ("working", .working),
            ("done", .done), ("waiting", .waiting), ("sad", .sad),
        ]
        try render(
            VStack(spacing: 24) {
                HStack(spacing: 24) {
                    ForEach(moods, id: \.0) { name, mood in
                        VStack(spacing: 6) {
                            FrogFace(mood: mood, size: 48)
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ZStack(alignment: .bottom) {
                    LilyPad().fill(Color.accentColor.opacity(0.22)).frame(width: 76, height: 26).offset(y: 4)
                    FrogFace(mood: .idle, size: 48)
                }
            }
            .padding(40)
            .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 620, height: 240), to: "frog-faces")
    }

    /// Activity lines opened: a group's steps, one step's diff, and a long thought streaming.
    /// `activity-open.png`, `activity-thinking.png`.
    func testRenderActivity() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
        let all = try events(dir.appending(path: "text-tools-text.jsonl"))
        let done = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        all.forEach(done.ingest)
        let groups = TurnFlow(try XCTUnwrap(done.turns.first).items).segments.compactMap { s -> ActivityGroup? in
            if case .activity(let g) = s { g } else { nil }
        }
        let edit = try XCTUnwrap(groups.flatMap(\.steps).first { $0.arg.hasSuffix("PaneView.swift") && $0.result?.diff != nil })
        try render(
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    ActivityLine(group: g, conversation: done, expanded: true)
                }
                ActivitySteps(steps: [edit], conversation: done)
                ActivityStepRow(item: edit, conversation: done, expanded: true)
            }
            .padding(28)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 900, height: 900), to: "activity-open")

        // A long thought streaming, after the reads.
        let cut = try XCTUnwrap(all.firstIndex {
            if case .itemStarted("r2", _) = $0.event { true } else { false }
        })
        let live = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        all[...cut].forEach(live.ingest)
        let delta = #"{"seq":999,"session":"s","created":1790600005000,"event":"item_delta","id":"r2","delta":{"type":"reasoning","text":"Two places use the title as identity: the row's .id and the selection binding in PaneView.\n\nBoth need the stable session id. The selection binding compares titles when it restores the selection after the library reloads, so after a rename it finds nothing and clears.\n\nKeying both on the id fixes the rename"}}"#
        live.ingest(try JSONDecoder.frog.decode(Envelope.self, from: Data(delta.utf8)))
        try render(transcript(live), size: CGSize(width: 900, height: 700), to: "activity-thinking")
        print("snapshots: \(outDir.path)")
    }

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
            sub(#"{"event":"item_started","id":"b","kind":{"type":"tool_call","name":"Read","arg":"crates/frog-engine/src/mcp.rs"}}"#),
            sub(#"{"event":"item_completed","id":"b","item":{"type":"tool_call","name":"Read","arg":"crates/frog-engine/src/mcp.rs","input":{},"outcome":"ok","output":"","display":null}}"#),
            sub(#"{"event":"item_started","id":"c","kind":{"type":"tool_call","name":"Grep","arg":"fn status"}}"#),
            sub(#"{"event":"status","model":"tang/Qwen/Qwen3-4B","mode":"default","cwd":"/tmp","messages":4,"context_tokens":5100,"context_window":32768,"tool_mode":"native","tier":"medium","tokens_per_sec":71.0,"todos":[]}"#),
            sub(#"{"event":"item_completed","id":"c","item":{"type":"tool_call","name":"Grep","arg":"fn status","input":{},"outcome":"ok","output":"","display":null}}"#),
            sub(#"{"event":"item_started","id":"d","kind":{"type":"message"}}"#),
            sub(#"{"event":"item_delta","id":"d","delta":{"type":"text","text":"Suspicious descriptions are caught by `suspicious()` in `crates/frog-engine/src/mcp.rs:836`, which checks"}}"#),
        ]
        let events = try lines.map { try JSONDecoder.frog.decode(Envelope.self, from: Data($0.utf8)) }
        let live = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        events.forEach(live.ingest)
        try render(transcript(live), size: CGSize(width: 900, height: 560), to: "subagent-live")

        let end = [
            #"{"seq":3,"session":"s","created":0,"event":"item_completed","id":"t1","item":{"type":"tool_call","name":"Task","arg":"Find MCP quarantine","input":{},"outcome":"ok","output":"Suspicious descriptions are caught by `suspicious()` in `crates/frog-engine/src/mcp.rs:836`, which checks each tool's description and schema against injection patterns and hidden Unicode. `Hub::status` and `Hub::catalog` leave quarantined tools out unless the server has `trust = true`.","display":null}}"#,
            #"{"seq":4,"session":"s","created":0,"event":"item_started","id":"m","kind":{"type":"message"}}"#,
            #"{"seq":5,"session":"s","created":0,"event":"item_completed","id":"m","item":{"type":"message","text":"In `mcp.rs`, `suspicious()` (line 836)."}}"#,
        ]
        try end.map { try JSONDecoder.frog.decode(Envelope.self, from: Data($0.utf8)) }.forEach(live.ingest)
        try render(transcript(live), size: CGSize(width: 900, height: 560), to: "subagent-done")
        print("snapshots: \(outDir.path)")
    }

    /// Agents as calm steps (docs/design/agents/calm.html): a turn that ran two agents (one
    /// failed) and waits on a third with a plan; its steps opened; the sidebar's agent rows
    /// while it runs, and the fold once it ends.
    func testRenderAgentsCalm() throws {
        func env(_ s: String) throws -> Envelope { try JSONDecoder.frog.decode(Envelope.self, from: Data(s.utf8)) }
        func sub(_ item: String, _ inner: String) -> String {
            #"{"seq":0,"session":"s","created":0,"event":"subagent","item":"\#(item)","inner":\#(inner)}"#
        }
        func task(_ id: String, _ arg: String, _ outcome: String, _ output: String) -> [String] {[
            #"{"seq":0,"session":"s","created":0,"event":"item_started","id":"\#(id)","kind":{"type":"tool_call","name":"Task","arg":"\#(arg)"}}"#,
            sub(id, #"{"event":"item_completed","id":"\#(id)a","item":{"type":"tool_call","name":"Grep","arg":"rail","input":{},"outcome":"ok","output":"","display":null}}"#),
            #"{"seq":0,"session":"s","created":0,"event":"item_completed","id":"\#(id)","item":{"type":"tool_call","name":"Task","arg":"\#(arg)","input":{},"outcome":"\#(outcome)","output":"\#(output)","display":null}}"#,
        ]}
        let todos = #"{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"completed"},{"content":"c","status":"completed"},{"content":"d","status":"in_progress"},{"content":"e","status":"pending"}]}"#
        let lines = [
            #"{"seq":1,"session":"s","created":0,"event":"turn_started","turn":1,"input":"Audit how the sidebar, the rail and the pill show subagents. Use agents for the three areas."}"#,
            #"{"seq":2,"session":"s","created":0,"event":"item_started","id":"r","kind":{"type":"tool_call","name":"Read","arg":"apps/FrogKit/UI/Transcript/TimelineRail.swift"}}"#,
            #"{"seq":3,"session":"s","created":0,"event":"item_completed","id":"r","item":{"type":"tool_call","name":"Read","arg":"apps/FrogKit/UI/Transcript/TimelineRail.swift","input":{},"outcome":"ok","output":"","display":null}}"#,
        ] + task("t1", "map the rail code", "ok", "The rail draws per turn.")
          + task("t2", "survey bg tasks", "error", "rate limited (429)")
          + [
            #"{"seq":0,"session":"s","created":0,"event":"item_started","id":"t3","kind":{"type":"tool_call","name":"Task","arg":"audit run sheet"}}"#,
            sub("t3", #"{"event":"item_completed","id":"p","item":{"type":"tool_call","name":"TodoWrite","arg":"","input":\#(todos),"outcome":"ok","output":"","display":null}}"#),
            sub("t3", #"{"event":"item_started","id":"q","kind":{"type":"tool_call","name":"Read","arg":"apps/FrogKit/UI/Transcript/SubagentView.swift"}}"#),
          ]
        let live = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        try lines.map(env).forEach(live.ingest)
        try render(transcript(live), size: CGSize(width: 760, height: 420), to: "agents-calm-live")
        let steps = try XCTUnwrap(live.turns.last?.items)
        try render(ActivitySteps(steps: steps, conversation: live).padding(24).frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 600, height: 200), to: "agents-calm-steps")
        let sidebar = VStack(alignment: .leading, spacing: 0) {
            SessionAgents(conversation: live, depth: 1) {}
        }
        try render(sidebar.padding(8).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .underPageBackgroundColor)),
                   size: CGSize(width: 300, height: 120), to: "agents-calm-sidebar")

        try [
            #"{"seq":0,"session":"s","created":0,"event":"item_completed","id":"t3","item":{"type":"tool_call","name":"Task","arg":"audit run sheet","input":{},"outcome":"ok","output":"done","display":null}}"#,
            #"{"seq":0,"session":"s","created":0,"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{"input_tokens":1,"output_tokens":1,"model_calls":1}}"#,
        ].map(env).forEach(live.ingest)
        XCTAssertEqual(live.agentList.done, 2)
        XCTAssertEqual(live.agentList.failed, 1)
        let folded = VStack(alignment: .leading, spacing: 0) {
            SessionAgents(conversation: live, depth: 1) {}
        }
        try render(folded.padding(8).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .underPageBackgroundColor)),
                   size: CGSize(width: 300, height: 60), to: "agents-calm-folded")
        print("snapshots: \(outDir.path)")
    }

    /// The terminal pane from a sample grid, and the preview pane on a local page: what the
    /// engine's side will drive.
    func testRenderPanes() throws {
        let c = Conversation(preview: URL(fileURLWithPath: "/tmp/demo"))
        let lines = [
            #"{"seq":1,"session":"s","created":0,"event":"pane_opened","id":"t1","kind":"terminal","title":"zsh","cwd":"/Users/cam/Developer/demo"}"#,
            #"{"seq":2,"session":"s","created":0,"event":"pane_screen","id":"t1","cols":60,"rows":12,"lines":["demo % npm run dev","","> demo@0.1.0 dev","> vite","","  VITE v5.4.2  ready in 312 ms","","  ➜  Local:   http://localhost:5173/","  ➜  Network: use --host to expose","","demo % "],"cursor":[10,7],"seq":3}"#,
            #"{"seq":3,"session":"s","created":0,"event":"pane_opened","id":"p1","kind":"preview","title":"Preview","url":null}"#,
        ]
        try lines.map { try JSONDecoder.frog.decode(Envelope.self, from: Data($0.utf8)) }.forEach(c.ingest)
        XCTAssertEqual(c.panes.panes.map(\.id), ["t1", "p1"])
        let hub = c.panes
        let terminal = try XCTUnwrap(hub.pane("t1"))
        try render(
            TerminalPane(pane: terminal, hub: hub).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 480, height: 320), to: "pane-terminal")
        let preview = try XCTUnwrap(hub.pane("p1"))
        let html = """
        <html><head><title>Demo</title></head><body style="font-family:-apple-system;padding:24px">
        <h1>Hello from the preview</h1><p>A form the model can read and drive.</p>
        <form id="login"><label>Email <input name="email" value="cam@example.com"></label>
        <button type="submit">Sign in</button></form></body></html>
        """
        try render(
            PreviewPane(pane: preview, hub: hub, html: html).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 480, height: 420), to: "pane-preview")
        hub.selected = .pane("t1")
        try render(
            PaneArea(conversation: c, height: 400, width: .constant(480)).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 480, height: 400), to: "pane-area")
        print("snapshots: \(outDir.path)")
    }

    /// Diagram cards, in dark and light: the model's diagrams from recent sessions (when
    /// present) and one laid out from Mermaid by the engine.
    func testRenderDiagrams() async throws {
        var diagrams: [(String, Diagram)] = []
        let sessions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/frog/sessions")
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
          subgraph engine [frog-engine]
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
            XCTFail("frog --mermaid failed")
        }
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "crates/frog-engine")
        if let d = await Diagram.codeMap(in: engine) {
            diagrams.append(("diagram-codemap", d))
            let full = DiagramCanvas(diagram: d)
                .environment(\.diagramStatic, true)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(full, size: CGSize(width: (d.layout?.width ?? 400) + 20, height: (d.layout?.height ?? 300) + 20), to: "codemap-full")
        } else {
            XCTFail("frog --map failed")
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


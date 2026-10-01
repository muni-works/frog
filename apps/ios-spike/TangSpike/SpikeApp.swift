import SwiftUI

/// Measures tang on this phone. Models are folders in Documents (copy them in with Finder or
/// `devicectl device copy to`). Launch with `--autobench <folder>` to run the bench headless;
/// results land in Documents/bench-<folder>.json either way.
@main
struct SpikeApp: App {
    @State private var runner = Runner()

    var body: some Scene {
        WindowGroup {
            ContentView(runner: runner)
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "--autobench"), i + 1 < args.count {
                        await runner.bench(model: args[i + 1])
                    }
                }
        }
    }
}

@MainActor @Observable
final class Runner {
    var log: [String] = []
    var busy = false
    var reply = ""
    private var tang: Tang?
    private var loaded: String?

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var models: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.documents.path)) ?? []
        return names.filter {
            FileManager.default.fileExists(atPath: Self.documents.appending(path: "\($0)/config.json").path)
        }.sorted()
    }

    private func say(_ s: String) {
        log.append(s)
        print("[spike] \(s)")
    }

    private func load(_ model: String) async throws -> Tang {
        if let tang, loaded == model { return tang }
        tang = nil
        let dir = Self.documents.appending(path: model)
        say("loading \(model) (footprint \(Int(Memory.footprintMB)) MB, \(Int(Memory.availableMB)) MB available)")
        let t = try await Task.detached { try Tang(dir: dir, context: 8192) }.value
        tang = t
        loaded = model
        say("loaded: \(t.info())")
        say("footprint \(Int(Memory.footprintMB)) MB, \(Int(Memory.availableMB)) MB available")
        return t
    }

    func bench(model: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var results: [[String: Any]] = []
        do {
            let t = try await load(model)
            for prompt in [512, 2048, 4096] {
                say("bench \(prompt)-token prompt, thermal \(ProcessInfo.processInfo.thermalState.name)")
                var r = await Task.detached { t.bench(prompt: prompt, gen: 128) }.value
                r["target_prompt"] = prompt
                r["footprint_mb"] = Memory.footprintMB
                r["available_mb"] = Memory.availableMB
                r["thermal"] = ProcessInfo.processInfo.thermalState.name
                results.append(r)
                say(Self.summary(r))
            }
        } catch {
            say("error: \(error)")
            results.append(["error": "\(error)"])
        }
        let doc: [String: Any] = ["model": model, "device": Self.deviceModel, "info": tang?.info() ?? [:], "runs": results]
        let url = Self.documents.appending(path: "bench-\(model).json")
        try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        say("wrote \(url.lastPathComponent)")
    }

    func ask(model: String, _ text: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        reply = ""
        do {
            let t = try await load(model)
            let usage = await Task.detached {
                t.chat([["role": "user", "content": text]], maxTokens: 512) { piece in
                    Task { @MainActor in self.reply += piece }
                    return true
                }
            }.value
            say("chat: \(Self.summary(usage))")
        } catch {
            say("error: \(error)")
        }
    }

    static func summary(_ r: [String: Any]) -> String {
        func turn(_ u: Any?) -> String {
            guard let u = u as? [String: Any] else { return "?" }
            let n = { (k: String) in (u[k] as? NSNumber)?.doubleValue ?? 0 }
            return String(format: "%.0f/%.0f cached, prefill %.0f tok/s, decode %.1f tok/s",
                          n("cached_tokens"), n("prompt_tokens"), n("prefill_tok_s"), n("decode_tok_s"))
        }
        if let e = r["error"] { return "error: \(e)" }
        if r["cold"] != nil { return "cold \(turn(r["cold"])) · warm \(turn(r["warm"]))" }
        return turn(r)
    }

    static var deviceModel: String {
        var s = utsname()
        uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

struct ContentView: View {
    let runner: Runner
    @State private var model = ""
    @State private var prompt = "Write a Rust function that reverses the words in a sentence."

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(runner.models, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Run bench") { Task { await runner.bench(model: model) } }
                        .disabled(model.isEmpty || runner.busy)
                }
                Section("Ask") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                    Button("Send") { Task { await runner.ask(model: model, prompt) } }
                        .disabled(model.isEmpty || runner.busy)
                    if !runner.reply.isEmpty { Text(runner.reply).font(.callout.monospaced()) }
                }
                Section("Log") {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("tang on iPhone")
            .onAppear { if model.isEmpty { model = runner.models.first ?? "" } }
        }
    }
}

import Foundation
import SwiftUI
import XCTest
@testable import Frog

/// Models are named and marked one way everywhere (docs/models.md): readable names from model
/// ids, and no view formatting a model on its own.
final class ModelIdentityTests: XCTestCase {
    func testNamesFromModelIDs() {
        let cases: [(String, String, String?)] = [
            ("mlx-community/Qwen3-8B-4bit", "Qwen3 8B", "4-bit"),
            ("qwen3:4b", "Qwen3 4B", nil),
            ("qwen3-coder:30b", "Qwen3 Coder 30B", nil),
            ("mlx-community/gemma-3-4b-it-4bit", "Gemma 3 4B", "4-bit"),
            ("Llama-3.1-8B-Instruct", "Llama 3.1 8B", nil),
            ("qwen2.5:3b", "Qwen2.5 3B", nil),
            ("llama3:latest", "Llama3", nil),
        ]
        for (id, name, variant) in cases {
            let c = ModelIdentity.cleanName(id)
            XCTAssertEqual(c.name, name, id)
            XCTAssertEqual(c.variant, variant, id)
        }
    }

    @MainActor
    func testPlacesFromSpecs() {
        XCTAssertEqual(ModelIdentity.of("apple/on-device", in: []).name, "Apple Intelligence")
        XCTAssertEqual(ModelIdentity.of("apple/on-device", in: []).place, .apple)
        XCTAssertEqual(ModelIdentity.of("tang/mlx-community/Qwen3-4B-4bit", in: []).place, .mac)
        XCTAssertEqual(ModelIdentity.of("tang/mlx-community/Qwen3-4B-4bit", in: []).name, "Qwen3 4B")
        XCTAssertEqual(ModelIdentity.of("ollama/qwen3:4b", in: []).spoken, "Qwen3 4B, on this Mac")
    }

    /// Frog Cloud's models go by their plain names, and old ids (an old log's `cloud/bull`)
    /// read as today's.
    @MainActor
    func testFrogCloudModelsByPlainNames() {
        XCTAssertEqual(ModelIdentity.of("cloud/deepseek-v4.1-flash", in: []).name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(ModelIdentity.of("cloud/bull", in: []).name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(ModelIdentity.of("cloud/bull", in: []).spec, "cloud/deepseek-v4.1-flash")
        XCTAssertEqual(ModelIdentity.of("frog/tree", in: []).name, "GLM-5.3 Flash")
        XCTAssertEqual(ModelIdentity.of("cloud/dart", in: []).name, "Qwen3 Coder Next")
        XCTAssertEqual(ProviderID.canonicalSpec("cloud/tree"), "cloud/glm-5.3-flash")
        XCTAssertEqual(ProviderID.canonicalSpec("ollama/tree"), "ollama/tree")
    }

    func testFitAndStateLines() {
        // Weights, a fifth more, and 2 GB of context room.
        XCTAssertEqual(ModelIdentity.neededGB(weights: 4.6), 8)
        XCTAssertEqual(ModelIdentity.neededGB(weights: 17), 23)
        func m(_ s: ModelIdentity.State) -> ModelIdentity {
            ModelIdentity(spec: "x/y", name: "Y", variant: nil, place: .mac, abilities: [], paramsB: nil,
                          context: nil, price: nil, state: s, downloadGB: 4.6)
        }
        XCTAssertNil(m(.ready).stateLine)
        XCTAssertEqual(m(.notDownloaded(gb: 4.6)).stateLine, "4.6 GB download")
        XCTAssertEqual(m(.downloading(fraction: 0.5)).stateLine, "2.3 GB of 4.6 GB")
        XCTAssertEqual(m(.needsKey(provider: "Anthropic")).stateLine, "Add an Anthropic key to use it")
        XCTAssertEqual(m(.needsKey(provider: "OpenAI")).stateLine, "Add an OpenAI key to use it")
        XCTAssertEqual(m(.wontFit(needsGB: 32, hasGB: 24)).stateLine, "Needs 32 GB, this Mac has 24")
        XCTAssertTrue(m(.wontFit(needsGB: 32, hasGB: 24)).state.dimmed)
        XCTAssertEqual(m(.notAllowed(project: "kiln")).stateLine, "kiln keeps code on your devices")
        XCTAssertTrue(m(.notAllowed(project: "kiln")).state.dimmed)
    }

    /// Views don't show raw specs or engine words; `ModelLabel` does the talking. Lines that
    /// are meant to (Settings' engine details, the detail card) end with `// advanced`.
    func testViewsNameModelsOneWay() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Frog/Views")
        let ui = try NSRegularExpression(pattern: #"(Text\(|\.help\(|title:|subtitle:|Label\(|Section\(|Button\()"#)
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let banned = try NSRegularExpression(pattern: #"\b(tier|tool calls|tool mode|tang|ollama)\b|tok/s"#, options: .caseInsensitive)
        let spec = try NSRegularExpression(pattern: #"\.spec\b"#)
        var problems: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            for (n, raw) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.contains("// advanced") else { continue }
                let r = NSRange(line.startIndex..., in: line)
                guard ui.firstMatch(in: line, range: r) != nil else { continue }
                // Ids and tags carry specs by design; they aren't shown.
                let shown = line.replacingOccurrences(of: #"id: "[^"]*""#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\.tag\([^)]*\)"#, with: "", options: .regularExpression)
                let where_ = "\(file.lastPathComponent):\(n + 1)"
                if spec.firstMatch(in: shown, range: NSRange(shown.startIndex..., in: shown)) != nil {
                    problems.append("\(where_) shows a raw spec: use ModelLabel or ModelIdentity.name")
                }
                for m in literal.matches(in: line, range: r) {
                    let text = (line as NSString).substring(with: m.range(at: 1))
                    if banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        problems.append("\(where_) says \"\(text)\": see the vocabulary in docs/models.md")
                    }
                }
            }
        }
        XCTAssert(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Cam's rule (docs/models.md, "Place color"): cloud green, local blue, everywhere. Any
    /// cloud is green, Anthropic and OpenAI as much as Frog Cloud.
    func testPlaceColorIsCloudGreenLocalBlue() {
        let cloud: [ModelIdentity.Place] = [.frogCloud, .cloud("Anthropic"), .cloud("OpenAI")]
        let local: [ModelIdentity.Place] = [.mac, .apple, .server("mew (RTX 3090)")]
        for p in cloud { XCTAssertEqual(Color.place(p), Tokens.placeCloud, "\(p)") }
        for p in local { XCTAssertEqual(Color.place(p), Tokens.placeLocal, "\(p)") }
        for p in cloud + local { XCTAssertEqual(p.color, Color.place(p)) }
        // That cloud green is the accent itself is checked on the JSON (apps/web/test/place.test.ts).
    }

    /// Every place annotation goes through `Color.place(_:)`: no surface picks its own green or
    /// blue for where a model runs, or colors a turn by who served it.
    func testPlaceAnnotationsGoThroughOneFunction() throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["FrogKit", "macos/Frog", "ios/Frog"].map { apps.appending(path: $0) }
        // A raw color on a line about a place, a served-by color, or the old Bool form.
        let banned = try NSRegularExpression(pattern: #"Color\.served|served\(|place\(cloud:|PlaceIcon\([^)]*tint:|ModelLabel\([^)]*tint:"#)
        let placeLine = try NSRegularExpression(pattern: #"(?i)(cloud|place|serving|frogCloud|cloudTarget)"#)
        let raw = try NSRegularExpression(pattern: #"\.(green|blue)\b|Color\.(green|blue)|Tokens\.accent|\.accentColor"#)
        var problems: [String] = []
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Tokens.swift" } ?? []
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    let r = NSRange(line.startIndex..., in: line), at = "\(file.lastPathComponent):\(i + 1)"
                    if banned.firstMatch(in: line, range: r) != nil { problems.append("\(at) colors a place its own way: use Color.place(_:)") }
                    if placeLine.firstMatch(in: line, range: r) != nil, raw.firstMatch(in: line, range: r) != nil,
                       line.contains("foregroundStyle") || line.contains("stroke") || line.contains(".tint(") {
                        problems.append("\(at) a raw green/blue on a place: use Color.place(_:)")
                    }
                }
            }
        }
        XCTAssert(problems.isEmpty, problems.joined(separator: "\n"))
    }
}

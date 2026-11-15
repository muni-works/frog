import XCTest
@testable import Frog

/// Speed and cost next to models (docs/models.md, "Cost and speed").
@MainActor
final class ModelStatsTests: XCTestCase {
    private func stats() -> ModelStats {
        let suite = "frog-model-stats-\(UUID().uuidString)"
        return ModelStats(defaults: UserDefaults(suiteName: suite)!)
    }

    private func usage(_ input: UInt64, _ output: UInt64, tps: Double? = nil, model: String? = "anthropic/sonnet") -> TurnUsage {
        TurnUsage(contextTokens: nil, inputTokens: input, outputTokens: output, modelCalls: 1, tokensPerSec: tps, model: model)
    }

    func testMoney() {
        XCTAssertEqual(ModelStats.money(0), "Free")
        XCTAssertEqual(ModelStats.money(0.004), "<$0.01")
        XCTAssertEqual(ModelStats.money(0.04), "$0.04")
        XCTAssertEqual(ModelStats.money(1.8412), "$1.84")
        XCTAssertEqual(ModelStats.speedText(38.4), "38 tok/s")
        XCTAssertEqual(Dollars.format(0), "$0")
        XCTAssertEqual(Dollars.format(15), "$15")
        XCTAssertEqual(Dollars.format(0.6), "$0.60")
        XCTAssertEqual(Dollars.format(12.5), "$12.50")
        XCTAssertEqual(CloudFormat.dollars(1250), "$12.50")
    }

    func testWordSpeedsMigrateToTokens() throws {
        let d = UserDefaults(suiteName: "ModelStatsTests.migrate")!
        d.removePersistentDomain(forName: "ModelStatsTests.migrate")
        // A store from before: speeds in words/s, no unit flag.
        d.set(Data(#"{"models":{"tang/q":{"speeds":[45],"inputs":[],"outputs":[]}},"spend":{},"prices":{}}"#.utf8), forKey: "modelStats")
        XCTAssertEqual(ModelStats(defaults: d).speed("tang/q")!, 60, accuracy: 1e-9)
        // Migrated once: a second load doesn't divide again.
        XCTAssertEqual(ModelStats(defaults: d).speed("tang/q")!, 60, accuracy: 1e-9)
    }

    func testSpeedIsAMedianInTokens() {
        let s = stats()
        XCTAssertNil(s.speed("tang/q"))
        for tps in [40.0, 60, 400] { s.record(usage(100, 10, tps: tps, model: "tang/q"), model: nil) }
        // Median 60 tokens/s.
        XCTAssertEqual(s.speed("tang/q")!, 60, accuracy: 1e-9)
    }

    func testTurnsArePricedAndAddedToTheWeek() {
        let s = stats()
        // Before prices are known, turns are free and uncounted.
        XCTAssertNil(s.cost(of: usage(10_000, 1_000)))
        s.learnPrices([entry("anthropic/sonnet", costIn: 3, costOut: 15)])
        XCTAssertEqual(s.cost(of: usage(10_000, 1_000))!, 0.045, accuracy: 1e-9)
        s.record(usage(10_000, 1_000), model: nil)
        s.record(usage(10_000, 1_000), model: nil)
        XCTAssertEqual(s.spentThisWeek, 0.09, accuracy: 1e-9)
        XCTAssertEqual(s.spentThisMonth, 0.09, accuracy: 1e-9)
        // A cap under what's spent pauses cloud models; none (0) never does.
        XCTAssertFalse(s.overCap)
        s.monthlyCap = 0.05
        XCTAssertTrue(s.overCap)
        s.monthlyCap = 0
        XCTAssertFalse(s.overCap)
    }

    func testCacheReadsArePricedAtTheCachedRate() {
        let s = stats()
        let spec = "vercel/anthropic/claude-opus-5.5"
        var u = usage(152_219, 6_500, model: spec)
        u.cachedTokens = 151_667
        // Opus list prices, $4 in and $20 out; the gateway lists cache reads at $0.40.
        s.learnPrices([entry(spec, costIn: 4, costOut: 20, cacheRead: 0.4)])
        XCTAssertEqual(s.cost(of: u)!, 0.1929, accuracy: 0.0005) // not $0.74 at the full input rate
        // Not listed: Anthropic's tenth of the input rate is the same here.
        s.learnPrices([entry(spec, costIn: 4, costOut: 20)])
        XCTAssertEqual(s.prices(spec)!.cacheRead, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.cost(of: u)!, 0.1929, accuracy: 0.0005)
        // Cache writes at 1.25× input; OpenAI-style caches at half.
        u.cacheWriteTokens = 552
        XCTAssertEqual(s.cost(of: u)!, 0.1929 + 552 * 4 * 0.25 / 1e6, accuracy: 0.0005)
        XCTAssertEqual(ModelStats.Prices(spec: "openai/gpt-5", input: 1.25, output: 10).cacheRead, 0.625, accuracy: 1e-9)
        XCTAssertEqual(ModelStats.Prices(spec: "cloud/qwen3-coder-next", input: 0.6, output: 2).cacheRead, 0.06, accuracy: 1e-9)
    }

    func testOldLogsTakeCacheCountsFromTheirCalls() throws {
        let u = try JSONDecoder.frog.decode(TurnUsage.self, from: Data(#"{"input_tokens":300,"output_tokens":5,"model_calls":2,"timing":{"wall_ms":1,"calls":[{"prompt_tokens":100,"cached_tokens":90},{"prompt_tokens":200,"cached_tokens":180}]}}"#.utf8))
        XCTAssertEqual(u.cached, 270)
        XCTAssertEqual(u.fresh, 30)
    }

    func testEstimatedCostUsesYourTurnSizes() {
        let s = stats()
        let m = ModelIdentity(spec: "anthropic/sonnet", name: "Sonnet", variant: nil, place: .cloud("Anthropic"),
                              abilities: [], paramsB: nil, context: nil, price: nil, costIn: 3, costOut: 15)
        // No history: 8k in, 1k out.
        XCTAssertEqual(s.estimatedTurnCost(m)!, 0.039, accuracy: 1e-9)
        s.record(usage(20_000, 2_000, model: "tang/q"), model: nil)
        XCTAssertEqual(s.estimatedTurnCost(m)!, 0.09, accuracy: 1e-9)
    }

    func testNewConversationsStartOnAppleThenTheLastPick() {
        let d = UserDefaults(suiteName: "frog-start-\(UUID().uuidString)")!
        XCTAssertEqual(Workspace.startingModel(d, apple: true), "apple/on-device")
        XCTAssertNil(Workspace.startingModel(d, apple: false))
        d.set("tang/mlx-community/Qwen3-8B-4bit", forKey: "lastModel")
        XCTAssertEqual(Workspace.startingModel(d, apple: true), "local/mlx-community/Qwen3-8B-4bit") // saved before the rename
        // A model fixed in Settings wins over the last pick.
        d.set("mew/mlx-community/Qwen3-8B-4bit", forKey: "defaultModel")
        XCTAssertEqual(Workspace.startingModel(d, apple: true), "local/mlx-community/Qwen3-8B-4bit")
        d.set("fixed", forKey: "newMessageModelPolicy")
        XCTAssertEqual(Workspace.startingModel(d, apple: true), "mew/mlx-community/Qwen3-8B-4bit")
    }

    private func entry(_ spec: String, costIn: Double, costOut: Double, cacheRead: Double? = nil) -> ModelEntry {
        let read = cacheRead.map { #","costCacheRead":\#($0)"# } ?? ""
        let json = """
        {"spec":"\(spec)","provider":"anthropic","model":"sonnet","source":"remote","tier":"strong","toolMode":"native",
         "info":{"spec":"\(spec)","provider":"anthropic","id":"sonnet","name":"Sonnet","inputs":["text"],"reasoning":false,"tools":true,"costIn":\(costIn),"costOut":\(costOut)\(read)}}
        """
        return try! JSONDecoder.frog.decode(ModelEntry.self, from: Data(json.utf8))
    }
}

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
        XCTAssertEqual(ModelStats.money(0.004), "<1¢")
        XCTAssertEqual(ModelStats.money(0.04), "4¢")
        XCTAssertEqual(ModelStats.money(1.8412), "$1.84")
        XCTAssertEqual(ModelStats.speedText(38.4), "38 words/s")
    }

    func testSpeedIsAMedianInWords() {
        let s = stats()
        XCTAssertNil(s.speed("tang/q"))
        for tps in [40.0, 60, 400] { s.record(usage(100, 10, tps: tps, model: "tang/q"), model: nil) }
        // Median 60 tokens/s, in words.
        XCTAssertEqual(s.speed("tang/q")!, 45, accuracy: 1e-9)
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

    private func entry(_ spec: String, costIn: Double, costOut: Double) -> ModelEntry {
        let json = """
        {"spec":"\(spec)","provider":"anthropic","model":"sonnet","source":"remote","tier":"strong","toolMode":"native",
         "info":{"spec":"\(spec)","provider":"anthropic","id":"sonnet","name":"Sonnet","inputs":["text"],"reasoning":false,"tools":true,"costIn":\(costIn),"costOut":\(costOut)}}
        """
        return try! JSONDecoder.frog.decode(ModelEntry.self, from: Data(json.utf8))
    }
}

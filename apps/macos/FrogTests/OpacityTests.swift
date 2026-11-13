import XCTest
@testable import Frog

/// Cam, 2026-11-12: a Frog Cloud turn reads as "Frog Cloud" whoever proxied it. Presentation is
/// opaque; the data behind it (`id`, `name`, `isThirdParty`) and the cost numbers stay truthful,
/// because a cache miss or a cost spike is debugged from them.
final class OpacityTests: XCTestCase {
    private func served(_ id: String, _ name: String, thirdParty: Bool) -> ServedBy {
        ServedBy(id: id, name: name, thirdParty: thirdParty)
    }

    func testAnUpstreamNeverReachesTheDisplayName() {
        // From `x-frog-upstream`: a third party the engine names.
        let s = served("workers-ai", "Cloudflare Workers AI", thirdParty: true)
        XCTAssertEqual(s.displayName, "Frog Cloud")
        // The record is untouched: the log keeps who really answered.
        XCTAssertEqual(s.id, "workers-ai")
        XCTAssertEqual(s.name, "Cloudflare Workers AI")
        XCTAssertTrue(s.isThirdParty)
        // An upstream frog has never heard of, named however the gateway likes.
        XCTAssertEqual(served("acme", "Acme Inference Ltd.", thirdParty: true).displayName, "Frog Cloud")
        // Frog Cloud's own GPUs are the one case where the data agrees with the label.
        let frog = served("frog", "Frog Cloud", thirdParty: false)
        XCTAssertEqual(frog.displayName, "Frog Cloud")
        XCTAssertFalse(frog.isThirdParty)
    }

    /// The leak a first pass misses: `/v1/models` may carry an explicit `served_by.name`, which
    /// the engine keeps verbatim. Display must not use it either.
    func testAListedServedByNameNeverReachesTheDisplayName() {
        let json = #"{"id":"workers-ai","name":"Cloudflare Workers AI","third_party":true}"#
        let s = try! JSONDecoder().decode(ServedBy.self, from: Data(json.utf8))
        XCTAssertEqual(s.displayName, "Frog Cloud")
        XCTAssertEqual(s.name, "Cloudflare Workers AI")
        XCTAssertEqual(s.id, "workers-ai")
        XCTAssertTrue(s.isThirdParty)
    }

    /// Cost is not opacity (Cam was explicit): a cold overflow turn costs several times a warm
    /// one, and the user still sees that number.
    @MainActor
    func testCostDisplayIsUnaffectedByTheOpacityChange() {
        let suite = "frog-opacity-\(UUID().uuidString)"
        let stats = ModelStats(defaults: UserDefaults(suiteName: suite)!)
        stats.learnPrices([entry("cloud/qwen3-coder-next", costIn: 0.2, costOut: 0.8, cacheRead: 0.02)])
        let cold = TurnUsage(contextTokens: nil, inputTokens: 10_000, outputTokens: 1_000, modelCalls: 1,
                             tokensPerSec: nil, model: "cloud/qwen3-coder-next",
                             servedBy: served("workers-ai", "Cloudflare Workers AI", thirdParty: true))
        let warm = TurnUsage(contextTokens: nil, inputTokens: 10_000, outputTokens: 1_000, cachedTokens: 8_000,
                             modelCalls: 1, tokensPerSec: nil, model: "cloud/qwen3-coder-next",
                             servedBy: served("frog", "Frog Cloud", thirdParty: false))
        let coldCost = stats.cost(of: cold)!
        let warmCost = stats.cost(of: warm)!
        XCTAssertGreaterThan(coldCost, warmCost)
        XCTAssertEqual(coldCost, 10_000 * 0.2 / 1_000_000 + 1_000 * 0.8 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(warmCost, 2_000 * 0.2 / 1_000_000 + 8_000 * 0.02 / 1_000_000 + 1_000 * 0.8 / 1_000_000, accuracy: 1e-12)
    }

    private func entry(_ spec: String, costIn: Double, costOut: Double, cacheRead: Double? = nil) -> ModelEntry {
        let read = cacheRead.map { #","costCacheRead":\#($0)"# } ?? ""
        let json = """
        {"spec":"\(spec)","provider":"cloud","model":"qwen3-coder-next","source":"remote","tier":"strong","toolMode":"native",
         "info":{"spec":"\(spec)","provider":"cloud","id":"qwen3-coder-next","name":"Qwen3 Coder Next","inputs":["text"],"reasoning":false,"tools":true,"costIn":\(costIn),"costOut":\(costOut)\(read)}}
        """
        return try! JSONDecoder.frog.decode(ModelEntry.self, from: Data(json.utf8))
    }
}

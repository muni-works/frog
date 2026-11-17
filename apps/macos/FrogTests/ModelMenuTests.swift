import XCTest
@testable import Frog

/// The composer's model menu lists this Mac's models first (Cam, 2026-11-17: "put local models
/// back in the mac menu"), as the hype reel shows them: Apple Intelligence, what's downloaded,
/// and the model that suits this Mac to get, each $0 a token.
@MainActor
final class ModelMenuTests: XCTestCase {
    private func model(_ spec: String, _ name: String, _ place: ModelIdentity.Place, _ state: ModelIdentity.State = .ready) -> ModelIdentity {
        var m = ModelIdentity(spec: spec, name: name, variant: nil, place: place, abilities: [.usesTools], paramsB: nil, context: nil, price: nil)
        m.state = state
        return m
    }

    func testThisMacComesFirstWithTheCurrentModelAndAModelToGet() {
        let apple = model("apple/on-device", "Apple Intelligence", .apple)
        let get = model("local/mlx-community/Qwen3-32B-4bit", "Qwen3 32B", .mac, .notDownloaded(gb: 18))
        let cloud = model("cloud/deepseek-v4.1-flash", "DeepSeek V4.1 Flash", .frogCloud)
        // A fresh Mac: the engine has listed nothing local yet, the chip says Apple Intelligence.
        let fresh = ModelMenu.thisMacModels(listed: [cloud], current: apple, suggestion: get)
        XCTAssertEqual(fresh.map(\.name), ["Apple Intelligence", "Qwen3 32B"])

        // Downloaded models come before the one still to get; nothing twice.
        let have = model("local/mlx-community/Qwen3-8B-4bit", "Qwen3 8B", .mac)
        let later = ModelMenu.thisMacModels(listed: [have, apple, cloud], current: have, suggestion: get)
        XCTAssertEqual(later.map(\.name), ["Apple Intelligence", "Qwen3 8B", "Qwen3 32B"])

        // A Frog Cloud current model stays in Frog Cloud's section.
        XCTAssertEqual(ModelMenu.thisMacModels(listed: [], current: cloud, suggestion: nil), [])
    }

    func testThisMacRowsSayTheyCostNothing() {
        XCTAssertEqual(ModelMenu.thisMacDetail(model("apple/on-device", "Apple Intelligence", .apple), tokensPerSecond: nil), "$0 a token")
        XCTAssertEqual(ModelMenu.thisMacDetail(model("local/x", "Qwen3 8B", .mac), tokensPerSecond: 41.4), "$0 a token · 41 tok/s")
        XCTAssertEqual(ModelMenu.thisMacDetail(model("local/y", "Qwen3 32B", .mac, .notDownloaded(gb: 18)), tokensPerSecond: nil), "18 GB")
    }

    /// Signed out of Frog Cloud, its rows say what they need instead of looking ready.
    func testSignedOutCloudRowsAskToSignIn() {
        XCTAssertEqual(ModelMenu.cloudTag(.needsKey(provider: ProviderID.cloudName)), "Sign in")
        XCTAssertEqual(ModelMenu.cloudTag(.needsKey(provider: "OpenRouter")), "Add key")
        XCTAssertNil(ModelMenu.cloudTag(.ready))
    }
}

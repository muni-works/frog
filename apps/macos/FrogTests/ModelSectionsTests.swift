import XCTest
@testable import Frog

/// The shared section order (docs/plans/2026-10-21-frog-account-design.md): This Mac, your
/// servers, frog cloud, then other clouds. frog cloud is always there, signed in or not.
@MainActor
final class ModelSectionsTests: XCTestCase {
    private var saved: (() -> [ProviderInfo])!

    override func setUp() async throws {
        saved = ModelContext.providers
    }

    override func tearDown() async throws {
        ModelContext.providers = saved
    }

    private func provider(_ id: String, _ name: String, local: Bool = false, custom: Bool = false,
                          key: String? = nil, rank: Int? = nil) -> ProviderInfo {
        ProviderInfo(id: id, name: name, kind: "openai", baseUrl: "", local: local, custom: custom,
                     key: key, keyUrl: "", connected: key != nil || local, rank: rank,
                     pinned: id == "cloud" ? true : nil)
    }

    private func providers(cloudKey: String?, server: Bool) -> [ProviderInfo] {
        var list = [
            provider("local", "This Mac", local: true),
            provider("cloud", "frog cloud", key: cloudKey),
            provider("anthropic", "Anthropic", key: "keychain"),
            provider("openai", "OpenAI", key: "env"),
        ]
        if server { list.append(provider("mew", "mew", local: true, custom: true)) }
        return list
    }

    private func entry(_ spec: String, source: String) -> ModelEntry {
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        return ModelEntry(spec: spec, provider: parts[0], model: parts[1], source: source, caps: nil,
                          tier: "medium", toolMode: "native", info: nil)
    }

    private func sections(cloudKey: String?, server: Bool, listCloud: Bool = true) -> [(title: String, models: [ModelIdentity])] {
        ModelContext.providers = { [self] in providers(cloudKey: cloudKey, server: server) }
        var entries = [
            entry("openai/gpt-5", source: "remote"),
            entry("anthropic/claude-sonnet-5", source: "remote"),
            entry("local/mlx-community/Qwen3-4B-4bit", source: "local"),
        ]
        if listCloud { entries.append(entry("cloud/qwen3-coder-next", source: "remote")) }
        if server { entries.append(entry("mew/qwen3:32b", source: "server")) }
        return ModelSections.make(usable: entries.map(ModelIdentity.init), suggested: [])
    }

    func testOrderWithServersSignedIn() {
        let s = sections(cloudKey: "keychain", server: true)
        XCTAssertEqual(s.map(\.title), ["This Mac", "On mew", "frog cloud", "Cloud · Anthropic", "Cloud · OpenAI"])
        XCTAssertEqual(s[2].models.map(\.state), [.ready])
    }

    func testOrderWithoutServersSignedIn() {
        let s = sections(cloudKey: "env", server: false)
        XCTAssertEqual(s.map(\.title), ["This Mac", "frog cloud", "Cloud · Anthropic", "Cloud · OpenAI"])
    }

    func testSignedOutFrogCloudStaysWithSignInAction() {
        for server in [true, false] {
            let s = sections(cloudKey: nil, server: server)
            let cloud = s.first { $0.title == "frog cloud" }
            XCTAssertNotNil(cloud)
            XCTAssertEqual(s.map(\.title).firstIndex(of: "frog cloud"), server ? 2 : 1)
            XCTAssertEqual(cloud?.models.first?.state, .needsKey(provider: "frog cloud"))
            XCTAssertEqual(cloud?.models.first?.stateLine, "Sign in or add a key to use it")
        }
    }

    /// An engine that doesn't list frog cloud yet still gets the section, from the built-in model.
    func testFrogCloudAlwaysPresent() {
        let s = sections(cloudKey: nil, server: false, listCloud: false)
        XCTAssertEqual(s.map(\.title), ["This Mac", "frog cloud", "Cloud · Anthropic", "Cloud · OpenAI"])
        XCTAssertEqual(s[1].models.map(\.spec), ["cloud/qwen3-coder-next"])
    }

    /// Old ids in saved state mean the same providers.
    func testOldIdsFold() {
        ModelContext.providers = { [self] in providers(cloudKey: "keychain", server: false) }
        XCTAssertEqual(ModelIdentity.of("frog-api/qwen3-coder-next", in: []).place, .frogCloud)
        XCTAssertEqual(ModelIdentity.of("tang/mlx-community/Qwen3-4B-4bit", in: []).place, .mac)
        for old in ["frog-api", "frog", "tang-cloud", "zest"] { XCTAssertEqual(ProviderID.canonical(old), "cloud") }
        XCTAssertEqual(ProviderID.canonicalSpec("tang/mlx-community/Qwen3-4B-4bit"), "local/mlx-community/Qwen3-4B-4bit")
    }

    /// The engine's rank wins; without it, the same order falls out of id/local/custom.
    func testProviderOrder() {
        let mixed = [provider("openai", "OpenAI"), provider("cloud", "frog cloud"),
                     provider("mew", "mew", local: true, custom: true), provider("tang", "tang", local: true)]
        XCTAssertEqual(ProviderInfo.sorted(mixed).map(\.id), ["tang", "mew", "cloud", "openai"])
        let ranked = mixed.enumerated().map { i, p in var p = p; p.rank = 10 - i; return p }
        XCTAssertEqual(ProviderInfo.sorted(ranked).map(\.id), ["tang", "mew", "cloud", "openai"])
    }

    func testCardKeyLine() {
        XCTAssertEqual(FrogCloudCard.keyLine("keychain"), "API key · Keychain")
        XCTAssertEqual(FrogCloudCard.keyLine("env"), "API key · FROG_API_KEY (from your environment; a saved key is ignored here)")
        XCTAssertNil(FrogCloudCard.keyLine(nil))
    }
}

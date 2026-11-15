import XCTest
@testable import Frog

/// Launch (#224, Cam 2026-10-30): every picker lists Frog Cloud's models only. The shared
/// order (docs/plans/2026-10-21-frog-account-design.md: This Mac, your servers, frog cloud,
/// then other clouds) returns when ModelSections.frogCloudOnly turns off.
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
            provider("cloud", "Frog Cloud", key: cloudKey),
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
        if listCloud { entries.append(entry("cloud/glm-5.3-flash", source: "remote")) }
        if server { entries.append(entry("mew/qwen3:32b", source: "server")) }
        return ModelSections.make(usable: entries.map(ModelIdentity.init), suggested: [])
    }

    /// Only Frog Cloud's models are listed; with a server, nothing else changes.
    func testOrderWithServersSignedIn() {
        let s = sections(cloudKey: "keychain", server: true)
        XCTAssertEqual(s.map(\.title), ["Frog Cloud"])
        XCTAssertEqual(s[0].models.map(\.state), [.ready])
    }

    /// Only Frog Cloud's models are listed, signed in without a key source in play.
    func testOrderWithoutServersSignedIn() {
        let s = sections(cloudKey: "env", server: false)
        XCTAssertEqual(s.map(\.title), ["Frog Cloud"])
    }

    /// Signed out, Frog Cloud's listed models stay, asking to sign in.
    func testSignedOutFrogCloudStaysWithSignInAction() {
        for server in [true, false] {
            let s = sections(cloudKey: nil, server: server)
            XCTAssertEqual(s.map(\.title), ["Frog Cloud"])
            XCTAssertEqual(s[0].models.first?.state, .needsKey(provider: "Frog Cloud"))
            XCTAssertEqual(s[0].models.first?.stateLine, "Sign in or add a key to use it")
        }
    }

    /// Frog Cloud's section is only what the engine listed: nothing built in fills it.
    func testNoFrogCloudSectionWhenNothingListedIt() {
        let s = sections(cloudKey: nil, server: false, listCloud: false)
        XCTAssertFalse(s.map(\.title).contains("Frog Cloud"))
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
        let mixed = [provider("openai", "OpenAI"), provider("cloud", "Frog Cloud"),
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

    /// Cam, 2026-11-12: "everything remote will go through frog cloud, let's not worry about the
    /// providers in the app." Bring-your-own-provider entry points are hidden, not deleted, and
    /// the list is still Frog Cloud only, so the picker says This Mac and Frog Cloud and nothing
    /// else. One constant flips both back.
    func testBringYourOwnProvidersAreHiddenNotDeleted() {
        XCTAssertTrue(ModelSections.providersHidden)
        XCTAssertTrue(ModelSections.frogCloudOnly)
        // The full list still knows every provider: hiding is presentation, not data loss.
        ModelContext.providers = { [self] in providers(cloudKey: "keychain", server: true) }
        let all = [
            entry("openai/gpt-5", source: "remote"),
            entry("anthropic/claude-sonnet-5", source: "remote"),
            entry("mew/qwen3:32b", source: "server"),
            entry("cloud/glm-5.3-flash", source: "remote"),
        ].map(ModelIdentity.init)
        // Every one of those identities still resolves and names its provider...
        XCTAssertEqual(ModelIdentity.of("anthropic/claude-sonnet-5", in: []).place.label, "Cloud · Anthropic")
        XCTAssertEqual(ModelIdentity.of("mew/qwen3:32b", in: []).place.label, "On mew")
        // ...while the picker's sections keep to Frog Cloud.
        XCTAssertEqual(ModelSections.make(usable: all, suggested: []).map(\.title), ["Frog Cloud"])
    }
}

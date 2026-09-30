import Foundation
import Observation

/// Providers and the models they offer, for Settings and the model picker. frog owns the
/// record (`~/.config/frog/models.json`, keys in the Keychain), so the terminal app sees the
/// same list; this reads it through frog and changes it through frog.
@MainActor
@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    private(set) var providers: [ProviderInfo] = []
    private(set) var catalog: [CatalogModel] = []
    private(set) var loadingCatalog = false
    /// The last thing that went wrong, for the UI to show.
    var error: String?
    /// Bumped when the model list changes, so pickers reload.
    private(set) var generation = 0

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func load() async {
        providers = (try? await Frog.json([ProviderInfo].self, args: ["--providers", "--json"], cwd: home)) ?? providers
    }

    func loadCatalog(refresh: Bool = false) async {
        loadingCatalog = true
        defer { loadingCatalog = false }
        let args = ["--catalog", "--json"] + (refresh ? ["--refresh"] : [])
        if let list = try? await Frog.json([CatalogModel].self, args: args, cwd: home) {
            catalog = list
        }
    }

    func provider(_ id: String) -> ProviderInfo? { providers.first { $0.id == id } }

    // MARK: Reachability

    /// Local apps (Ollama, LM Studio) and your servers that answered when last asked, by id.
    /// Missing means not asked yet.
    private(set) var reachable: [String: Bool] = [:]

    /// Ask every local app and server whether it's up, briefly and all at once.
    func probe() async {
        let targets = providers.filter(\.local)
        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for p in targets { group.addTask { (p.id, await Self.answers(p)) } }
            var out: [String: Bool] = [:]
            for await (id, ok) in group { out[id] = ok }
            return out
        }
        reachable = results
    }

    /// Whether a server answers its model list within a second and a half.
    nonisolated static func answers(_ p: ProviderInfo) async -> Bool {
        var base = p.baseUrl.hasSuffix("/") ? String(p.baseUrl.dropLast()) : p.baseUrl
        let path: String
        if p.kind == "ollama" {
            if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
            path = "/api/tags"
        } else {
            path = "/models"
        }
        guard let url = URL(string: base + path) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral)
        return (try? await session.data(for: request)).map { _ in true } ?? false
    }

    func name(of provider: String) -> String { self.provider(provider)?.name ?? provider }

    /// Save a key (empty removes it), then refresh what it unlocks.
    func setKey(_ key: String, for id: String) async {
        await run(["--set-key", id], input: key)
        await load()
        await loadCatalog(refresh: true)
    }

    func addServer(id: String, name: String, url: String, ollama: Bool) async -> Bool {
        let ok = await run(["--add-provider", id, url, "--provider-kind", ollama ? "ollama" : "openai", "--provider-name", name])
        await load()
        return ok
    }

    func remove(_ id: String) async {
        await run(["--remove-provider", id])
        await load()
    }

    func setEnabled(_ spec: String, _ on: Bool) async {
        if let i = catalog.firstIndex(where: { $0.spec == spec }) { catalog[i].enabled = on }
        await run([on ? "--enable-model" : "--disable-model", spec])
    }

    @discardableResult
    private func run(_ args: [String], input: String? = nil) async -> Bool {
        do {
            try await Frog.command(args, input: input)
            error = nil
            generation += 1
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

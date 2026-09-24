import Foundation
import Observation

/// Providers and the models they offer, for Settings and the model picker. kiln owns the
/// record (`~/.config/kiln/models.json`, keys in the Keychain), so the terminal app sees the
/// same list; this reads it through kiln and changes it through kiln.
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
        providers = (try? await Kiln.json([ProviderInfo].self, args: ["--providers", "--json"], cwd: home)) ?? providers
    }

    func loadCatalog(refresh: Bool = false) async {
        loadingCatalog = true
        defer { loadingCatalog = false }
        let args = ["--catalog", "--json"] + (refresh ? ["--refresh"] : [])
        if let list = try? await Kiln.json([CatalogModel].self, args: args, cwd: home) {
            catalog = list
        }
    }

    func provider(_ id: String) -> ProviderInfo? { providers.first { $0.id == id } }

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
            try await Kiln.command(args, input: input)
            error = nil
            generation += 1
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

extension CatalogModel {
    /// "$3 / $15 per M tokens", or nil when unknown.
    var price: String? {
        guard let i = costIn, let o = costOut else { return nil }
        if i == 0, o == 0 { return "Free" }
        return "\(Self.dollars(i)) in · \(Self.dollars(o)) out per M"
    }

    var contextLabel: String? {
        context.map { $0 >= 1_000_000 ? String(format: "%gM", Double($0) / 1_000_000) : "\($0 / 1000)k" }
    }

    private static func dollars(_ v: Double) -> String {
        v < 1 ? String(format: "$%.2f", v) : String(format: "$%g", (v * 100).rounded() / 100)
    }
}

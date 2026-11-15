import Foundation

/// On the Mac, what `ModelIdentity` needs to know comes from the Mac's own stores.
extension ModelContext {
    @MainActor
    static func useMac() {
        providers = { ProviderStore.shared.providers }
        reachable = { ProviderStore.shared.reachable[$0] }
        download = { repo in
            switch ModelDownloads.shared.states[repo] {
            case .downloading(let f)?: .downloading(fraction: f)
            case .failed(let e)?: .failed(e)
            case .done?: .done
            case nil: nil
            }
        }
        suggestedGB = { repo in SuggestedModel.all.first { $0.repo == repo }?.approxGB }
    }
}

extension ModelIdentity {
    /// A model frog recommends downloading.
    @MainActor
    init(_ suggested: SuggestedModel) {
        let cleaned = Self.cleanName(suggested.repo)
        var abilities: Abilities = [.usesTools]
        if suggested.repo.lowercased().contains("gemma") { abilities = [.seesImages] }
        self.init(
            spec: suggested.spec,
            name: suggested.title,
            variant: cleaned.variant,
            place: .mac,
            abilities: abilities,
            paramsB: nil,
            context: nil,
            price: nil
        )
        repo = suggested.repo
        downloadGB = suggested.approxGB
        state = Self.state(place: .mac, provider: ProviderID.local, repo: suggested.repo, gb: suggested.approxGB,
                           installed: ModelDownloads.isInstalled(suggested.repo))
    }
}

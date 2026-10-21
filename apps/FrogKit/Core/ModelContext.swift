import Foundation

/// What naming and placing a model needs to know about the machine it runs on: the providers
/// (and whether each is up), downloads in flight, what frog suggests. Each is read through to
/// its source, so a view that asks is updated when it changes. The Mac fills these from its
/// own stores; a phone, from what the Mac tells it.
@MainActor
enum ModelContext {
    enum Download: Equatable {
        case downloading(fraction: Double)
        case failed(String)
        case done
    }

    static var providers: () -> [ProviderInfo] = { [] }
    static var reachable: (String) -> Bool? = { _ in nil }
    static var download: (String) -> Download? = { _ in nil }
    static var suggestedGB: (String) -> Double? = { _ in nil }

    static func provider(_ id: String) -> ProviderInfo? { providers().first { ProviderID.same($0.id, id) } }
    static func name(of provider: String) -> String {
        ProviderID.displayName(provider) ?? self.provider(provider)?.name ?? provider
    }
}

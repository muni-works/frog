import Combine
import Foundation
import Sparkle

/// Sparkle updates for the release build. Debug builds (eco.frog.dev), test hosts and builds
/// without an update key never check, so a stray build can't replace itself with a release.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private(set) var canCheck = false

    var enabled: Bool { controller != nil }

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Bundle.main.bundleIdentifier == "eco.frog", !SingleInstance.isTesting, !key.isEmpty else {
            controller = nil
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func check() { controller?.checkForUpdates(nil) }
}

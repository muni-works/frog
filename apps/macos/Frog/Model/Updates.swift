import Combine
import Foundation
import Sparkle

/// Sparkle updates for the release build. Debug builds (toys.frog.dev), test hosts and builds
/// without an update key never check, so a stray build can't replace itself with a release.
///
/// With graceful restarts on (`UpdateDrain.enabled`), the delegate hands the install step to
/// frog: it drains every engine inside the shared budget, writes the resume manifest, and
/// only then invokes Sparkle's install handler — which terminates the app and relaunches the
/// new bundle. Engines that miss the deadline are killed; their turns resume as a crash
/// would, so the fallback is never worse than the old instant-kill path.
@MainActor
@Observable
final class Updates: NSObject {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private(set) var canCheck = false

    var enabled: Bool { controller != nil }

    private override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Bundle.main.bundleIdentifier == "toys.frog", !SingleInstance.isTesting, !key.isEmpty else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func check() { controller?.checkForUpdates(nil) }

    /// The drain → manifest → install-and-relaunch loop, callable without Sparkle (the debug
    /// menu's "Simulate Update" exercises it on any build).
    func drainThenInstall(immediate: @escaping () -> Void) {
        Task { @MainActor in
            await UpdateDrain.drainAll()
            SessionRegistry.shared.manifestForUpdate()
            immediate()
        }
    }
}

extension Updates: SPUUpdaterDelegate {
    /// Sparkle is about to install and relaunch. Take over: drain first, then install.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard UpdateDrain.enabled else { return false }
        drainThenInstall {
            immediateInstallationBlock()
        }
        return true
    }
}

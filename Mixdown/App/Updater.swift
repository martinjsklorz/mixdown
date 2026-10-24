import Foundation
import Observation
import Sparkle

/// Keeps Mixdown up to date with Sparkle, from the appcast `make release` attaches to the latest
/// GitHub release. Only release builds have the key updates are signed with (`SUPublicEDKey`);
/// builds from source don't, so they get no updater, and the menu item and settings are hidden.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check or an update is already under way.
    private(set) var canCheckForUpdates = false
    /// Mirror Sparkle's, which also changes when the user answers its first-launch question.
    var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init(bundle: Bundle = .main) {
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !publicKey.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.automaticallyChecksForUpdates
                Task { @MainActor in self?.syncAutomaticallyChecks(value) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.automaticallyDownloadsUpdates
                Task { @MainActor in self?.syncAutomaticallyDownloads(value) }
            },
        ]
    }

    var isAvailable: Bool { controller != nil }

    /// Shows Sparkle's window, which says when Mixdown is up to date.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // Only assigned when different, so `didSet` doesn't write the same value back to Sparkle.
    private func syncAutomaticallyChecks(_ value: Bool) {
        if automaticallyChecksForUpdates != value { automaticallyChecksForUpdates = value }
    }

    private func syncAutomaticallyDownloads(_ value: Bool) {
        if automaticallyDownloadsUpdates != value { automaticallyDownloadsUpdates = value }
    }
}

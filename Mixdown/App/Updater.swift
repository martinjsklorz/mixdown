import Foundation
import Observation
import Sparkle

/// Keeps Mixdown up to date with Sparkle, from the appcast `make release` attaches to the latest
/// GitHub release. Only release builds have the key updates are signed with (`SUPublicEDKey`);
/// builds from source don't, so they get no updater, and the menu item and settings are hidden.
///
/// Checks Sparkle schedules by itself are held back while `isBusy`, e.g. recording, so its
/// update window doesn't pop up in the middle of a meeting. The next scheduled one finds the update.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = Delegate()

    /// Whether Mixdown is busy with something an update window would get in the way of.
    var isBusy: @MainActor () -> Bool {
        get { delegate.isBusy }
        set { delegate.isBusy = newValue }
    }
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
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        // The values come from the change, as the updater itself is the main actor's and these
        // closures may run elsewhere.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.syncAutomaticallyChecks(value) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
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

extension Updater {
    /// Holds back scheduled update checks while `isBusy`.
    /// `@unchecked Sendable`: `isBusy` is only touched on the main actor.
    private final class Delegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
        @MainActor var isBusy: @MainActor () -> Bool = { false }

        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            guard updateCheck == .updatesInBackground else { return }
            // Sparkle calls its delegate on the main thread.
            let isBusy = MainActor.assumeIsolated { self.isBusy() }
            guard isBusy else { return }
            throw CocoaError(.userCancelled)
        }
    }
}

import Foundation

extension AppEnvironment {
    /// Whether a model the settings call for is neither on disk nor downloading: the speech
    /// model, the speaker model while telling speakers apart, and an open summary model while
    /// summarizing.
    var needsSetupDownloads: Bool {
        needsSpeechModel || needsSpeakerModel || needsSummaryModel
    }

    /// Whether any of those models is downloading.
    var isDownloadingSetupModels: Bool {
        if case .preparingModel = coordinator.phase { return true }
        return speakerModelDownload.progress != nil || summaryModelDownload?.progress != nil
    }

    /// Downloads every model `needsSetupDownloads` counts, side by side.
    func startSetupDownloads() {
        if needsSpeechModel {
            let coordinator = coordinator
            Task { await coordinator.prepareEngine() }
        }
        if needsSpeakerModel { speakerModelDownload.start() }
        if needsSummaryModel { summaryModelDownload?.start() }
    }

    private var needsSpeechModel: Bool {
        !coordinator.isModelDownloaded && coordinator.isIdle
    }

    private var needsSpeakerModel: Bool {
        preferences.identifiesSpeakers && !speakerModelDownload.isDownloaded
            && speakerModelDownload.progress == nil
    }

    private var needsSummaryModel: Bool {
        guard preferences.summarizesNotes, let download = summaryModelDownload else { return false }
        return !download.isDownloaded && download.progress == nil
    }
}

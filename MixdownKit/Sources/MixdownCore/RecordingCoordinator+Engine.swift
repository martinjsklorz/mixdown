import Foundation
import os

extension RecordingCoordinator {
    /// Downloads/loads the model ahead of the first recording, reporting progress via `phase`.
    /// Stopped by `cancelPreparation()` or by cancelling the calling task.
    public func prepareEngine() async {
        guard isIdle else { return }

        restartProgressEstimate()
        phase = .preparingModel(progress: 0)
        let preparation = Task { [engine, progress = preparationProgressHandler()] in
            try await engine.prepare(progress: progress)
        }
        self.preparation = preparation
        let result = await withTaskCancellationHandler {
            await preparation.result
        } onCancel: {
            preparation.cancel()
        }

        self.preparation = nil
        isCancellingPreparation = false
        // Checked on every outcome: a failed or cancelled download may still have finished.
        isModelDownloaded = engine.isDownloaded
        switch result {
        case .success:
            logger.info("Transcription engine ready")
            phase = .idle
        case .failure where preparation.isCancelled:
            logger.info("Preparing engine cancelled")
            phase = .idle
        case .failure(let error):
            logger.error("Preparing engine failed: \(error.localizedDescription, privacy: .public)")
            failWithModelError(error)
        }
    }

    /// Re-checks whether the model is downloaded, for an engine that can only tell asynchronously
    /// (see `TranscriptionEngine.refreshDownloadStatus()`). Call it once the coordinator is created.
    public func refreshModelStatus() async {
        await engine.refreshDownloadStatus()
        isModelDownloaded = engine.isDownloaded
    }

    /// Tells the engine about a new `options.language`, unless a recording holds it: that one is
    /// transcribed in the language it started with, and the engine follows once it's done.
    func syncEngineLanguage() {
        guard !isEngineHeldForRecording, options.language != engineLanguage else { return }
        engineLanguage = options.language
        engine.languageDidChange(to: options.language)
        isModelDownloaded = engine.isDownloaded
        Task { await refreshModelStatus() }
    }

    /// Keeps the engine's model loaded, and its language, until `releaseEngine()`.
    func holdEngine() {
        isEngineHeldForRecording = true
        engine.recordingWillStart()
    }

    func releaseEngine() {
        engine.recordingDidFinish()
        isEngineHeldForRecording = false
        syncEngineLanguage()
    }

    /// Stops an in-progress model download. Files already fetched are kept, so the next
    /// `prepareEngine()` (or recording) resumes from them. The phase becomes `.idle` once the
    /// engine has stopped, which `isCancellingPreparation` tells meanwhile. Ignored while
    /// `isPreparingModelForRecording`.
    public func cancelPreparation() {
        guard canCancelPreparation, let preparation else { return }
        isCancellingPreparation = true
        preparation.cancel()
    }

    /// Deletes the downloaded model to free disk space. Recording is unavailable until it's
    /// downloaded again. Ignored unless idle with the model on disk.
    public func deleteModel() async {
        guard isIdle, isModelDownloaded else { return }
        isDeletingModel = true
        do {
            try await engine.deleteModel()
            logger.info("Deleted transcription model")
            phase = .idle
        } catch {
            logger.error("Deleting model failed: \(error.localizedDescription, privacy: .public)")
            failWithModelError(error)
        }
        // Checked either way: a failed delete may have removed some files.
        isModelDownloaded = engine.isDownloaded
        isDeletingModel = false
    }

    func failWithModelError(_ error: any Error) {
        phase = .failed(message: error.localizedDescription)
        modelError = error.localizedDescription
    }

    /// Forwards the engine's preparation progress to `updatePreparationProgress` from any thread.
    private func preparationProgressHandler() -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updatePreparationProgress(progress)
            }
        }
    }

    private func updatePreparationProgress(_ progress: Double) {
        guard case .preparingModel = phase, progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        progressEstimator.add(progress: clamped, at: now())
        phase = .preparingModel(progress: clamped)
    }

    /// Downloads the model again if it went away while recording, as macOS may remove its own
    /// speech model at any time. Shown as `.preparingModel` with its progress, rather than as a
    /// transcription stuck at 0% while the engine fetches the model by itself. Returns to
    /// `.transcribing` once it's back.
    func prepareModelIfMissing() async throws {
        await engine.refreshDownloadStatus()
        isModelDownloaded = engine.isDownloaded
        guard !isModelDownloaded else { return }

        logger.info("Model went away while recording; downloading it again")
        restartProgressEstimate()
        phase = .preparingModel(progress: 0)
        isPreparingModelForRecording = true
        defer {
            isPreparingModelForRecording = false
            isModelDownloaded = engine.isDownloaded
        }
        try await engine.prepare(progress: preparationProgressHandler())

        restartProgressEstimate()
        phase = .transcribing(progress: 0)
    }

    /// Starts a new estimate of `timeRemaining` at 0% progress, now.
    func restartProgressEstimate() {
        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
    }
}

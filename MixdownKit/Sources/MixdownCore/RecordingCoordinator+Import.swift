import Foundation
import os

extension RecordingCoordinator {
    /// Transcribes the audio of the file at `url`, an audio or a video file, and saves it as a note
    /// like a recording's: translated and summarized if those are on, and named after its summary,
    /// or else after the file. The note is dated when the file was recorded, if it says.
    ///
    /// Shown as `.transcribing` while the file is read and transcribed, with `importingFileName`,
    /// then `.translating` and `.summarizing`. Stopped by `cancelImport()` or by cancelling the
    /// calling task, which saves nothing. Ignored unless `canImportAudio`.
    public func importAudio(from url: URL) async {
        guard canImportAudio, let audioFileDecoder else { return }
        // Taken now, like a recording's as it starts.
        let options = options
        importingFileName = url.lastPathComponent
        recordingSummaryTemplate = summaryTemplate
        isRecordingSummaryTemplateChosen = false
        holdEngine()
        phase = .transcribing(progress: 0)
        logger.info("Importing audio")

        let importing = Task {
            await transcribeImport(from: url, options: options, decoder: audioFileDecoder)
        }
        self.importing = importing
        await withTaskCancellationHandler {
            await importing.value
        } onCancel: {
            importing.cancel()
        }

        self.importing = nil
        importingFileName = nil
        recordingSummaryTemplate = nil
        releaseEngine()
    }

    /// Stops the import under way, without saving a note. Ignored if there's none.
    public func cancelImport() {
        importing?.cancel()
    }

    private func transcribeImport(
        from url: URL,
        options: TranscriptionOptions,
        decoder: any AudioFileDecoding
    ) async {
        let name = url.lastPathComponent
        do {
            let audio = try await decoder.decode(url)
            try Task.checkCancellation()
            guard audio.duration >= Self.minimumRecordingDuration else {
                logger.info("Not importing \(audio.duration, format: .fixed(precision: 2)) s of audio, too short")
                phase = .failed(message: Self.tooShortImportMessage(for: name))
                return
            }
            logger.info("Transcribing \(audio.duration, format: .fixed(precision: 1)) s of imported audio")

            try await prepareModelIfMissing()
            let track = NotePipeline.RecordedTrack(
                lane: 0,
                device: .importedFile(at: url),
                parts: [],
                samples: audio.samples,
                speech: [],
                duration: audio.duration,
                offset: 0
            )
            let input = NotePipeline.Input(
                tracks: [track],
                options: options,
                details: NotePipeline.NoteDetails(
                    startedAt: audio.recordedAt ?? now(),
                    duration: audio.duration,
                    sources: [track.device],
                    trigger: .imported,
                    isCall: false,
                    untitledName: url.deletingPathExtension().lastPathComponent
                )
            )
            let outcome = try await pipeline.makeNote(from: input) {
                takeSummaryTemplate(otherwise: summaryTemplate)
            }
            show(outcome.messages)
        } catch {
            // Engines may throw their own errors when cancelled.
            if error is CancellationError || Task.isCancelled {
                logger.info("Import cancelled")
                phase = .idle
                return
            }
            logger.error("Importing audio failed: \(error.localizedDescription, privacy: .public)")
            if case TranscriptionError.modelUnavailable = error {
                failWithModelError(error)
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }
}

import Foundation
import os

extension RecordingCoordinator {
    /// How many pieces a live engine is fed between updates of the import's progress, so a long
    /// file doesn't redraw the progress bar thousands of times. 16 pieces are about 5 s of audio.
    nonisolated static let liveImportProgressInterval = 16

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
        restartProgressEstimate()
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
            // Reading the file took a while without progress, which would skew the estimate.
            restartProgressEstimate()
            phase = .transcribing(progress: 0)
            let transcript =
                if engine.transcribesLive {
                    try await transcribeLive(audio.samples, options: options)
                } else {
                    try await transcribe(audio.samples, options: options)
                }
            try Task.checkCancellation()

            let messages = try await saveNote(
                transcript: transcript,
                template: summaryTemplate,
                details: NoteDetails(
                    startedAt: audio.recordedAt ?? now(),
                    duration: audio.duration,
                    sources: [.importedFile(at: url)],
                    trigger: .imported,
                    isCall: false,
                    untitledName: url.deletingPathExtension().lastPathComponent
                )
            )
            show(messages)
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

    /// `samples` transcribed in one go by an engine that transcribes after recording.
    private func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcript {
        let id = UUID()
        transcriptionProgress = TranscriptionProgress(sessionID: id, sampleCounts: [samples.count])
        return try await engine.transcribe(
            samples,
            options: options,
            progress: progressHandler(track: 0, sessionID: id)
        )
    }

    /// `samples` fed to a live session in the pieces a recording's would be, as fast as it takes
    /// them.
    private func transcribeLive(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcript {
        let id = UUID()
        transcriptionProgress = TranscriptionProgress(sessionID: id, sampleCounts: [samples.count])
        let live = try await engine.makeLiveSession(options: options)
        var text = LiveTranscript(speakers: [nil])
        var start = 0
        var pieces = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(start + Self.liveFeedSampleCount, samples.count)
            text.apply(try await live.push(Array(samples[start..<end])), fromSource: 0, startHostTime: nil)
            start = end
            pieces += 1
            if pieces.isMultiple(of: Self.liveImportProgressInterval) {
                updateTranscriptionProgress(Double(end) / Double(samples.count), track: 0, sessionID: id)
            }
        }
        text.apply(try await live.finish(), fromSource: 0, startHostTime: nil)
        updateTranscriptionProgress(1, track: 0, sessionID: id)
        return Transcript(segments: text.segments(fromSource: 0), language: options.language)
    }
}

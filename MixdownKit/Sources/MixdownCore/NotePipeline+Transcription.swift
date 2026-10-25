import Foundation
import os

extension NotePipeline {
    /// Each track's transcript, on the input's timeline: from the live text if there is any, else
    /// from the tracks' samples. A track that fails doesn't take the others with it: the
    /// transcripts are the tracks that worked, and the failure is returned alongside.
    func transcribe(_ input: Input) async throws -> ([TrackTranscript], TrackFailure?) {
        if let liveText = input.liveText {
            return (transcripts(from: liveText, of: input.tracks, language: input.options.language), nil)
        }
        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        didChangeStage(.transcribing(progress: 0))
        defer {
            // Updates still in flight are dropped, and the estimate doesn't outlive the transcription.
            transcriptionProgress = nil
            progressEstimator = RemainingTimeEstimator()
        }
        if engine.transcribesLive {
            return (try await transcribeLive(input.tracks, options: input.options), nil)
        }
        var options = input.options
        options.vocabularyTerms = vocabulary.terms
        return try await transcribeSeparately(input.tracks, options: options)
    }

    /// Each track's transcript from what the live sessions recognized, with the words' times.
    private func transcripts(
        from liveText: LiveTranscript,
        of tracks: [RecordedTrack],
        language: String?
    ) -> [TrackTranscript] {
        tracks.map { track in
            TrackTranscript(
                track: track,
                transcript: Self.shifted(
                    Transcript(segments: liveText.segments(fromSource: track.lane), language: language),
                    by: track.offset
                ),
                words: liveText.words(fromSource: track.lane).map { segment in
                    segment.map { LiveWord(text: $0.text, start: $0.start + track.offset, end: $0.end + track.offset) }
                }
            )
        }
    }

    /// Transcribes each track on its own, so speech stays attributed to its source. Tracks are
    /// submitted together; the engine decides how many it runs at once (speech-swift runs one at a
    /// time, since they share the GPU anyway).
    private func transcribeSeparately(
        _ tracks: [RecordedTrack],
        options: TranscriptionOptions
    ) async throws -> ([TrackTranscript], TrackFailure?) {
        let engine = engine
        let audible = tracks.filter { $0.duration >= RecordingCoordinator.minimumRecordingDuration }
        for track in tracks {
            logger.info(
                "Track \(track.device.name, privacy: .public): \(track.duration, format: .fixed(precision: 1)) s starting at \(track.offset, format: .fixed(precision: 2)) s"
            )
        }

        let id = startProgress(of: audible)
        let results = await withTaskGroup(
            of: (Int, Result<Transcript, any Error>).self,
            returning: [Result<Transcript, any Error>].self
        ) { group in
            for (index, track) in audible.enumerated() {
                let progress = progressHandler(track: index, id: id)
                group.addTask {
                    do {
                        let transcript = try await engine.transcribe(
                            track.samples,
                            options: options,
                            progress: progress
                        )
                        // Engines needn't report progress (e.g. for a source without speech), but the
                        // bar mustn't wait on a source that's done.
                        progress(1)
                        return (index, .success(NotePipeline.shifted(transcript, by: track.offset)))
                    } catch {
                        // A failed source is done too, as far as the bar is concerned.
                        progress(1)
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<Transcript, any Error>](
                repeating: .failure(CancellationError()),
                count: audible.count
            )
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        var transcripts: [TrackTranscript] = []
        var failedDevices: [AudioInputDevice] = []
        var firstError: (any Error)?
        for (track, result) in zip(audible, results) {
            switch result {
            case .success(let transcript):
                transcripts.append(TrackTranscript(track: track, transcript: transcript))
            // Cancelling the transcription stops every track; none of them failed.
            case .failure(let error) where error is CancellationError || Task.isCancelled:
                throw CancellationError()
            case .failure(let error):
                logger.error(
                    "Transcribing \(track.device.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                firstError = firstError ?? error
                for device in track.parts.map(\.device) where !failedDevices.contains(where: { $0.id == device.id }) {
                    failedDevices.append(device)
                }
            }
        }
        let failure = firstError.map { TrackFailure(devices: failedDevices, error: $0) }
        return (transcripts, failure)
    }

    /// Each track's samples fed to a live session of its own, in the pieces a recording's would
    /// be, as fast as it takes them. Throws the first error, as for a recording that stops live
    /// transcription.
    private func transcribeLive(
        _ tracks: [RecordedTrack],
        options: TranscriptionOptions
    ) async throws -> [TrackTranscript] {
        let id = startProgress(of: tracks)
        var transcripts: [TrackTranscript] = []
        for (index, track) in tracks.enumerated() {
            let samples = track.samples
            let live = try await engine.makeLiveSession(options: options)
            var text = LiveTranscript(speakers: [nil])
            var start = 0
            var pieces = 0
            while start < samples.count {
                try Task.checkCancellation()
                let end = min(start + RecordingCoordinator.liveFeedSampleCount, samples.count)
                text.apply(try await live.push(Array(samples[start..<end])), fromSource: 0, startHostTime: nil)
                start = end
                pieces += 1
                if pieces.isMultiple(of: Self.liveProgressInterval) {
                    updateProgress(Double(end) / Double(samples.count), track: index, id: id)
                }
            }
            text.apply(try await live.finish(), fromSource: 0, startHostTime: nil)
            updateProgress(1, track: index, id: id)
            let transcript = Transcript(segments: text.segments(fromSource: 0), language: options.language)
            transcripts.append(
                TrackTranscript(
                    track: track,
                    transcript: Self.shifted(transcript, by: track.offset),
                    words: text.words(fromSource: 0).map { segment in
                        segment.map {
                            LiveWord(text: $0.text, start: $0.start + track.offset, end: $0.end + track.offset)
                        }
                    }
                )
            )
        }
        return transcripts
    }

    // MARK: - Progress

    /// Starts tracking the progress of transcribing `tracks`. Returns the transcription's ID, which
    /// its updates must carry.
    private func startProgress(of tracks: [RecordedTrack]) -> UUID {
        let progress = TranscriptionProgress(sampleCounts: tracks.map(\.samples.count))
        transcriptionProgress = progress
        return progress.id
    }

    /// Forwards one track's progress to `updateProgress` from any thread.
    private func progressHandler(track index: Int, id: UUID) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateProgress(progress, track: index, id: id)
            }
        }
    }

    private func updateProgress(_ progress: Double, track index: Int, id: UUID) {
        // Updates still in flight when the transcription ends are dropped.
        guard var transcriptionProgress, transcriptionProgress.id == id,
            transcriptionProgress.fractions.indices.contains(index), progress.isFinite
        else { return }
        let fraction = max(transcriptionProgress.fractions[index], min(max(progress, 0), 1))
        let finishesTrack = fraction == 1 && transcriptionProgress.fractions[index] < 1
        transcriptionProgress.fractions[index] = fraction
        self.transcriptionProgress = transcriptionProgress
        let total = transcriptionProgress.total
        // Tracks go at very different paces: one without speech is done in a moment, and its share
        // of the bar with it. The time left is extrapolated from the tracks still running only,
        // rather than from a rate that took in that jump.
        if finishesTrack, transcriptionProgress.fractions.contains(where: { $0 < 1 }) {
            progressEstimator = RemainingTimeEstimator()
        }
        progressEstimator.add(progress: total, at: now())
        didChangeStage(.transcribing(progress: total))
    }
}

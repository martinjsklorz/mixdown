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
            return try await transcribeLive(input.tracks, options: input.options)
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
        tracks.map { TrackTranscript(liveText: liveText, source: $0.lane, track: $0, language: language) }
    }

    /// The tracks long enough to transcribe, logging all of them.
    private func audible(_ tracks: [RecordedTrack]) -> [RecordedTrack] {
        for track in tracks {
            logger.info(
                "Track \(track.device.name, privacy: .public): \(track.duration, format: .fixed(precision: 1)) s starting at \(track.offset, format: .fixed(precision: 2)) s"
            )
        }
        return tracks.filter { $0.duration >= Self.minimumTrackDuration }
    }

    /// Transcribes each track on its own, so speech stays attributed to its source. Tracks are
    /// submitted together; the engine decides how many it runs at once (speech-swift runs one at a
    /// time, since they share the GPU anyway).
    private func transcribeSeparately(
        _ tracks: [RecordedTrack],
        options: TranscriptionOptions
    ) async throws -> ([TrackTranscript], TrackFailure?) {
        let engine = engine
        let audible = audible(tracks)

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
                        return (index, .success(transcript.shifted(by: track.offset)))
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

        let transcripts = zip(audible, results).map { track, result in
            result.map { TrackTranscript(track: track, transcript: $0) }
        }
        return try collect(transcripts, of: audible)
    }

    /// Each track's samples fed to a live session of its own, in the pieces a recording's would
    /// be, as fast as it takes them. A track whose session fails doesn't take the others with it,
    /// as for `transcribeSeparately`.
    private func transcribeLive(
        _ tracks: [RecordedTrack],
        options: TranscriptionOptions
    ) async throws -> ([TrackTranscript], TrackFailure?) {
        let audible = audible(tracks)
        let id = startProgress(of: audible)
        var results: [Result<TrackTranscript, any Error>] = []
        for (index, track) in audible.enumerated() {
            do {
                results.append(.success(try await transcribeLive(track, index: index, id: id, options: options)))
            } catch {
                // Cancelling stops every track, so the rest aren't fed either.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // A failed track is done too, as far as the bar is concerned.
                updateProgress(1, track: index, id: id)
                results.append(.failure(error))
            }
        }
        return try collect(results, of: audible)
    }

    /// `track`'s samples fed to a live session; it's track `index` of the transcription `id`.
    private func transcribeLive(
        _ track: RecordedTrack,
        index: Int,
        id: UUID,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript {
        let samples = track.samples
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
            if pieces.isMultiple(of: Self.liveProgressInterval) {
                updateProgress(Double(end) / Double(samples.count), track: index, id: id)
            }
        }
        text.apply(try await live.finish(), fromSource: 0, startHostTime: nil)
        updateProgress(1, track: index, id: id)
        return TrackTranscript(liveText: text, source: 0, track: track, language: options.language)
    }

    /// The transcripts of `tracks` that worked, from each one's result, and the failure of the
    /// others. Throws if the transcription was cancelled.
    private func collect(
        _ results: [Result<TrackTranscript, any Error>],
        of tracks: [RecordedTrack]
    ) throws -> ([TrackTranscript], TrackFailure?) {
        var transcripts: [TrackTranscript] = []
        var failedDevices: [AudioInputDevice] = []
        var firstError: (any Error)?
        for (track, result) in zip(tracks, results) {
            switch result {
            case .success(let transcript):
                transcripts.append(transcript)
            // Cancelling the transcription stops every track; none of them failed.
            case .failure(let error) where error is CancellationError || Task.isCancelled:
                throw CancellationError()
            case .failure(let error):
                logger.error(
                    "Transcribing \(track.device.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                firstError = firstError ?? error
                for device in track.devices where !failedDevices.contains(where: { $0.id == device.id }) {
                    failedDevices.append(device)
                }
            }
        }
        let failure = firstError.map { TrackFailure(devices: failedDevices, error: $0) }
        return (transcripts, failure)
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

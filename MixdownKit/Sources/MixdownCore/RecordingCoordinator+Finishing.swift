import Foundation
import os

extension RecordingCoordinator {
    /// Transcribes and saves a finished recording, one track per lane of `session`.
    func finish(_ session: Session, lanes: [LaneAudio], interruption: (any Error)?) async {
        reconcileSelection()
        defer {
            showsLiveTranscript = false
            liveTranscript = LiveTranscript(speakers: [])
            liveCaptions = nil
        }

        let offsets = AudioTrack.startOffsets(of: lanes.map(\.track))
        let tracks = zip(session.lanes, lanes).enumerated().compactMap { index, pair -> RecordedTrack? in
            guard let device = pair.0.firstDevice else { return nil }
            return RecordedTrack(
                lane: index,
                device: device,
                parts: pair.1.parts,
                samples: pair.1.track.samples,
                speech: pair.1.speech,
                duration: pair.1.track.duration,
                offset: offsets[index]
            )
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            // An interruption this early explains itself, like capture failing to start.
            phase = .failed(message: interruption?.localizedDescription ?? Self.tooShortMessage)
            return
        }

        restartProgressEstimate()
        phase = .transcribing(progress: 0)
        do {
            try await prepareModelIfMissing()
            var transcript: Transcript
            var trackFailure: TrackFailure?
            if engine.transcribesLive {
                transcript = transcriptFromLiveText(tracks, language: session.options.language)
            } else if let track = tracks.first, tracks.count == 1 {
                transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: tracks)
                transcript = try await engine.transcribe(
                    track.samples,
                    options: session.options,
                    progress: progressHandler(track: 0, sessionID: session.id)
                )
            } else {
                (transcript, trackFailure) = try await transcribeSeparately(tracks, session: session)
            }
            transcript = vocabulary.apply(to: transcript)
            let (translation, translationError) = await translate(transcript)
            let template = recordingSummaryTemplate ?? (session.isCall ? callSummaryTemplate : summaryTemplate)
            // The template can't change once the summary is under way.
            recordingSummaryTemplate = nil
            let summary = await summarize(translation ?? transcript, template: template)
            let note = Note(
                title: NoteTitle.make(
                    for: session.startedAt,
                    summaryTitle: summary?.title,
                    isCall: session.isCall,
                    language: summary?.language ?? (translation ?? transcript).language
                ),
                createdAt: session.startedAt,
                duration: duration,
                sources: session.devices,
                engine: engine.info,
                transcript: transcript,
                translation: translation,
                summary: summary,
                trigger: session.trigger,
                isCall: session.isCall,
                template: summarizer == nil ? nil : template,
                // Described up to now, as the user may have still been typing when it stopped.
                moments: moments.map { Moment(id: $0.id, time: min($0.time, duration), text: $0.text) }
                    .sorted { $0.time < $1.time },
                talkTimeline: session.measuresTalkTime ? talkTimeline(of: tracks, duration: duration) : nil
            )
            // Kept until it's saved: the folder can go away while recording or transcribing, e.g.
            // when its drive is disconnected or goes to sleep.
            pendingNotes.append(note)
            let saveError = await savePendingNotes()
            let messages = [
                interruption.map(Self.interruptedMessage(for:)),
                trackFailure.map { Self.untranscribedMessage(for: $0.devices, error: $0.error) },
                translationError.map(Self.untranslatedMessage(for:)),
                pendingNotes.isEmpty ? nil : Self.unsavedMessage(for: saveError ?? NoteWritingError.noFolder),
            ].compactMap { $0 }
            if messages.isEmpty {
                phase = .idle
            } else {
                let message = messages.joined(separator: " ")
                unsavedNoteMessage = pendingNotes.isEmpty ? nil : message
                phase = .failed(message: message)
            }
            // A live model that failed to load needs the same retry as an offline one.
            if let interruption, case TranscriptionError.modelUnavailable = interruption {
                modelError = interruption.localizedDescription
            }
        } catch is CancellationError {
            logger.info("Finishing recording cancelled")
            phase = .idle
        } catch {
            logger.error("Finishing recording failed: \(error.localizedDescription, privacy: .public)")
            if case TranscriptionError.modelUnavailable = error {
                failWithModelError(error)
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// The transcript in `translationLanguage`, or `nil` if translation is off, the transcript is
    /// empty or in that language already, or translating fails. The note is saved either way, so a
    /// failure is returned to be mentioned alongside it rather than thrown.
    private func translate(_ transcript: Transcript) async -> (Transcript?, (any Error)?) {
        guard let translator, let translationLanguage, !transcript.isEmpty else { return (nil, nil) }
        phase = .translating
        do {
            return (try await translator.translate(transcript, to: translationLanguage), nil)
        } catch is CancellationError {
            return (nil, nil)
        } catch {
            let name = translator.info.displayName
            logger.error(
                "Translating with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return (nil, error)
        }
    }

    /// The transcript's summary, or `nil` if there's no summarizer, it isn't available or it
    /// fails. The note is saved either way, so a failure is only logged.
    private func summarize(_ transcript: Transcript, template: SummaryTemplate) async -> NoteSummary? {
        guard let summarizer, !transcript.isEmpty else { return nil }
        let name = summarizer.info.displayName
        if case .unavailable(let reason) = summarizer.availability {
            logger.info("Not summarizing, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return nil
        }
        phase = .summarizing
        do {
            let summary = try await summarizer.summarize(transcript, template: template)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.error(
                "Summarizing with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The note's transcript from what the live sessions recognized: per track like
    /// `transcribeSeparately`, merged by time when there are several.
    private func transcriptFromLiveText(_ tracks: [RecordedTrack], language: String?) -> Transcript {
        let transcripts = tracks.map { track in
            Self.shifted(
                Transcript(segments: liveTranscript.segments(fromSource: track.lane), language: language),
                by: track.offset
            )
        }
        guard tracks.count > 1 else { return transcripts.first ?? Transcript(segments: []) }
        let lanes = tracks.map(\.device)
        let sources = zip(tracks, transcripts).flatMap { track, transcript in
            Self.sources(of: transcript, track: track, among: lanes, labels: sourceLabels)
        }
        return TranscriptMerger.merge(sources)
    }

    /// When the user and the others talked, from the microphone and system audio tracks. `nil`
    /// without both, or if nobody talked.
    private func talkTimeline(of tracks: [RecordedTrack], duration: TimeInterval) -> TalkTimeline? {
        let speech = { (kind: AudioSourceKind) -> [Range<TimeInterval>]? in
            let ofKind = tracks.filter { $0.device.kind == kind }
            guard !ofKind.isEmpty else { return nil }
            return ofKind.flatMap { Self.shifted($0.speech, by: $0.offset) }
        }
        guard let microphone = speech(.microphone), let systemAudio = speech(.systemAudio) else { return nil }
        let timeline = TalkTimeline(
            labels: sourceLabels,
            microphone: microphone,
            systemAudio: systemAudio,
            duration: duration
        )
        return timeline.total.total > 0 ? timeline : nil
    }

    /// Transcribes each track on its own, so speech stays attributed to its source, then merges the
    /// labeled transcripts by time. Tracks are submitted together; the engine decides how many it
    /// runs at once (speech-swift runs one at a time, since they share the GPU anyway).
    ///
    /// A track that fails doesn't take the others with it: the transcript has the tracks that
    /// worked, and the failure is returned alongside. Throws the failure instead if the tracks
    /// that worked have no speech, e.g. because every track failed.
    private func transcribeSeparately(
        _ tracks: [RecordedTrack],
        session: Session
    ) async throws -> (Transcript, TrackFailure?) {
        let engine = engine
        let options = session.options
        let sourceLabels = sourceLabels
        let audible = tracks.filter { $0.duration >= Self.minimumRecordingDuration }
        for track in tracks {
            logger.info(
                "Track \(track.device.name, privacy: .public): \(track.duration, format: .fixed(precision: 1)) s starting at \(track.offset, format: .fixed(precision: 2)) s"
            )
        }

        transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: audible)
        let results = await withTaskGroup(
            of: (Int, Result<Transcript, any Error>).self,
            returning: [Result<Transcript, any Error>].self
        ) { group in
            for (index, track) in audible.enumerated() {
                let progress = progressHandler(track: index, sessionID: session.id)
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
                        return (index, .success(RecordingCoordinator.shifted(transcript, by: track.offset)))
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

        // A lane that switched microphones becomes one source per device, so with several
        // microphones each part is named after the device that recorded it.
        let lanes = tracks.map(\.device)
        var sources: [SourceTranscript] = []
        var failedDevices: [AudioInputDevice] = []
        var firstError: (any Error)?
        for (track, result) in zip(audible, results) {
            switch result {
            case .success(let transcript):
                sources += Self.sources(of: transcript, track: track, among: lanes, labels: sourceLabels)
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
        // With no speech from the tracks that worked, the note would only be empty, so the
        // recording fails as a whole.
        let transcript = TranscriptMerger.merge(sources)
        if let firstError, transcript.isEmpty { throw firstError }
        let failure = firstError.map { TrackFailure(devices: failedDevices, error: $0) }
        return (transcript, failure)
    }

    /// `transcript` of `track` as one labeled source per device that recorded part of it, in order
    /// of first use. `lanes` are the first devices of all of the recording's tracks.
    private nonisolated static func sources(
        of transcript: Transcript,
        track: RecordedTrack,
        among lanes: [AudioInputDevice],
        labels: SourceLabels
    ) -> [SourceTranscript] {
        var parts: [(device: AudioInputDevice, transcript: Transcript)] = []
        for segment in transcript.segments {
            let device = track.device(at: segment.start)
            if let index = parts.firstIndex(where: { $0.device.id == device.id }) {
                parts[index].transcript.segments.append(segment)
            } else {
                parts.append((device, Transcript(segments: [segment], language: transcript.language)))
            }
        }
        return parts.map { device, part in
            SourceTranscript(device: device, label: labels.label(for: device, among: lanes), transcript: part)
        }
    }

    /// `transcript` with its times moved later by `offset` seconds.
    private nonisolated static func shifted(_ transcript: Transcript, by offset: TimeInterval) -> Transcript {
        var transcript = transcript
        for i in transcript.segments.indices {
            transcript.segments[i].start += offset
            transcript.segments[i].end += offset
        }
        return transcript
    }

    /// `spans` moved later by `offset` seconds.
    nonisolated static func shifted(
        _ spans: [Range<TimeInterval>],
        by offset: TimeInterval
    ) -> [Range<TimeInterval>] {
        spans.map { (offset + $0.lowerBound)..<(offset + $0.upperBound) }
    }

    /// Forwards one track's progress to `updateTranscriptionProgress` from any thread.
    private func progressHandler(track index: Int, sessionID: UUID) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateTranscriptionProgress(progress, track: index, sessionID: sessionID)
            }
        }
    }

    private func updateTranscriptionProgress(_ progress: Double, track index: Int, sessionID: UUID) {
        // Updates still in flight when the transcription ends are dropped.
        guard case .transcribing = phase, var transcriptionProgress, transcriptionProgress.sessionID == sessionID,
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
        phase = .transcribing(progress: total)
    }
}

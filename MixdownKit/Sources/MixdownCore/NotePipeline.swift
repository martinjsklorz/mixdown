import Foundation
import Observation
import os

/// Turns a finished recording or an imported file into a saved note: transcribes its tracks,
/// tells apart the people on system audio, merges the tracks by time, corrects the transcript
/// with `vocabulary`, names its speakers, translates and summarizes it, then saves it with
/// `saver`.
///
/// `RecordingCoordinator` runs every recording and every import through it, so both make the
/// same notes. The settings are read as each step starts, so changing them while a recording is
/// transcribed still applies to it.
@MainActor
@Observable
final class NotePipeline {
    /// Adds a summary to each note. `nil` while summaries are off.
    var summarizer: (any Summarizer)?
    /// Whether notes are named after their summary's title. Off, they're named after the time
    /// recorded, or an imported file's name.
    var titlesNotesFromSummary = true
    /// Translates each transcript into `translationLanguage`.
    var translator: (any Translator)?
    var translationLanguage: String?
    var vocabulary = Vocabulary()
    /// Whether the spell checker knows a word, in the transcript's language if it's known, so
    /// fuzzy vocabulary entries leave it alone.
    @ObservationIgnored var isKnownWord: @MainActor (_ word: String, _ language: String?) -> Bool = { _, _ in false }
    /// Called with what fuzzy vocabulary entries corrected in a transcript, if anything.
    @ObservationIgnored var didMatchFuzzily: @MainActor ([Vocabulary.FuzzyMatch]) -> Void = { _ in }
    /// Renames the speakers the diarizer told apart.
    var speakerNamer: (any Summarizer)?
    /// Speaker names for multi-track notes.
    var sourceLabels: SourceLabels
    /// Called as each stage starts, and as transcription progresses.
    @ObservationIgnored var didChangeStage: (Stage) -> Void = { _ in }

    let engine: any TranscriptionEngine
    let saver: NoteSaver
    let now: @Sendable () -> Date
    let logger = Logger(subsystem: "app.mixdown", category: "pipeline")

    /// How many pieces a live engine is fed between updates of the progress, so a long file
    /// doesn't redraw the progress bar thousands of times. 16 pieces are about 5 s of audio.
    nonisolated static let liveProgressInterval = 16

    /// Tracks shorter than this aren't transcribed, as there's too little audio for speech.
    nonisolated static let minimumTrackDuration: TimeInterval = 0.5

    /// Audio is handed to live sessions in pieces of at least this many samples (320 ms, the step
    /// Nemotron works in) rather than per capture buffer, which can be a hundred times a second.
    nonisolated static let liveFeedSampleCount = 5_120

    /// Fed while transcribing; empty otherwise.
    var progressEstimator = RemainingTimeEstimator()
    /// Per-track progress of the transcription in flight.
    @ObservationIgnored var transcriptionProgress: TranscriptionProgress?

    init(
        engine: any TranscriptionEngine,
        saver: NoteSaver,
        summarizer: (any Summarizer)?,
        translator: (any Translator)?,
        translationLanguage: String?,
        sourceLabels: SourceLabels,
        now: @escaping @Sendable () -> Date
    ) {
        self.engine = engine
        self.saver = saver
        self.summarizer = summarizer
        self.translator = translator
        self.translationLanguage = translationLanguage
        self.sourceLabels = sourceLabels
        self.now = now
    }

    /// Estimated seconds until the transcription is done, while transcribing. `nil` until there's
    /// enough progress to extrapolate from (a few seconds in).
    var timeRemaining: TimeInterval? { progressEstimator.remaining }

    /// Makes a note of `input` and saves it, or keeps it in the saver if it can't be saved yet.
    /// Returns what to tell the user about, e.g. a track that couldn't be transcribed or a
    /// translation that failed. Throws if no track could be transcribed, without saving anything,
    /// and if the task is cancelled.
    /// - Parameter template: The summary template, asked for just before summarizing, as the user
    ///   may pick another while the recording is transcribed.
    func makeNote(from input: Input, template: () -> SummaryTemplate) async throws -> Outcome {
        var (transcripts, trackFailure) = try await transcribe(input)
        let diarizedLanes: Set<Int>
        (transcripts, diarizedLanes) = try await identifySpeakers(in: transcripts, using: input.diarizer)
        let (transcript, namable) = merged(transcripts, of: input.tracks, diarizedLanes: diarizedLanes)
        // With no speech from the tracks that worked, the note would only be empty, so it fails as
        // a whole.
        if let trackFailure, transcript.isEmpty { throw trackFailure.error }
        var (note, translationError) = try await makeNote(
            transcript: transcript,
            namingSpeakers: namable,
            template: template,
            details: input.details
        )
        // The recording is kept to transcribe again, with the track that failed.
        note.recordingID = trackFailure == nil ? input.details.recordingID : nil
        // Kept until it's saved: the folder can go away while recording or transcribing, e.g.
        // when its drive is disconnected or goes to sleep.
        let saveError = await saver.save(note)
        return Outcome(trackFailure: trackFailure, translationError: translationError, saveError: saveError)
    }

    /// Corrects `transcript` with the vocabulary, names its speakers, translates and summarizes it.
    /// Also returns why translating failed, if it did.
    private func makeNote(
        transcript: Transcript,
        namingSpeakers speakers: [String],
        template: () -> SummaryTemplate,
        details: NoteDetails
    ) async throws -> (Note, (any Error)?) {
        let isKnownWord = isKnownWord
        let language = transcript.language
        let correction = vocabulary.correct(transcript) { isKnownWord($0, language) }
        var transcript = correction.transcript
        if !correction.fuzzyMatches.isEmpty { didMatchFuzzily(correction.fuzzyMatches) }
        let names: [String: String]
        (transcript, names) = await nameSpeakers(speakers, in: transcript)
        try Task.checkCancellation()
        let (translation, translationError) = await translate(transcript)
        try Task.checkCancellation()
        let template = template()
        let summary = await summarize(translation ?? transcript, moments: details.moments, template: template)
        try Task.checkCancellation()
        let summaryTitle = summary.map(\.title).flatMap {
            !titlesNotesFromSummary || $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let note = Note(
            title: NoteTitle.make(
                for: details.startedAt,
                summaryTitle: summaryTitle ?? details.untitledName,
                isCall: details.isCall,
                callApp: details.callApp,
                language: summary?.language ?? (translation ?? transcript).language
            ),
            createdAt: details.startedAt,
            duration: details.duration,
            sources: details.sources,
            engine: engine.info,
            transcript: transcript,
            translation: translation,
            summary: summary,
            trigger: details.trigger,
            isCall: details.isCall,
            callApp: details.callApp,
            template: summarizer == nil ? nil : template,
            moments: details.moments,
            talkTimeline: details.talkTimeline.map { talkTimeline($0, named: names) }
        )
        return (note, translationError)
    }

    /// `timeline` with its sides labeled as the transcript has them: by `sourceLabels` as of now,
    /// and by the name a whole side got from `names`, e.g. the one person on system audio.
    private func talkTimeline(_ timeline: TalkTimeline, named names: [String: String]) -> TalkTimeline {
        var timeline = timeline
        let microphone = sourceLabels.label(for: .microphone)
        let systemAudio = sourceLabels.label(for: .systemAudio)
        timeline.microphoneLabel = names[microphone] ?? microphone
        timeline.systemAudioLabel = names[systemAudio] ?? systemAudio
        return timeline
    }

    /// The transcript in `translationLanguage`, or `nil` if translation is off, the transcript is
    /// empty or in that language already, or translating fails. The note is saved either way, so a
    /// failure is returned to be mentioned alongside it rather than thrown.
    private func translate(_ transcript: Transcript) async -> (Transcript?, (any Error)?) {
        guard let translator, let translationLanguage, !transcript.isEmpty else { return (nil, nil) }
        didChangeStage(.translating)
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

    /// The transcript's summary, covering the moments the user marked, or `nil` if there's no
    /// summarizer, it isn't available or it fails. The note is saved either way, so a failure is
    /// only logged.
    private func summarize(
        _ transcript: Transcript,
        moments: [Moment],
        template: SummaryTemplate
    ) async -> NoteSummary? {
        guard let summarizer, !transcript.isEmpty else { return nil }
        let name = summarizer.info.displayName
        if case .unavailable(let reason) = summarizer.availability {
            logger.info("Not summarizing, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return nil
        }
        didChangeStage(.summarizing)
        do {
            let summary = try await summarizer.summarize(transcript, moments: moments, template: template)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.error(
                "Summarizing with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Speakers

    /// `transcripts` with the speakers of the system audio told apart by `diarizer`, and the lanes
    /// whose speakers were. A track the diarizer fails on keeps its transcript as it was; the
    /// failure is only logged.
    private func identifySpeakers(
        in transcripts: [TrackTranscript],
        using diarizer: (any SpeakerDiarizer)?
    ) async throws -> ([TrackTranscript], Set<Int>) {
        guard let diarizer else { return (transcripts, []) }
        var transcripts = transcripts
        var diarizedLanes = Set<Int>()
        for index in transcripts.indices {
            let track = transcripts[index].track
            guard track.device.kind == .systemAudio, !track.samples.isEmpty, !transcripts[index].transcript.isEmpty
            else { continue }
            didChangeStage(.identifyingSpeakers)
            do {
                let started = now()
                let turns = try await diarizer.diarize(track.samples).map { $0.shifted(by: track.offset) }
                transcripts[index].transcript.segments = SpeakerAssignment.label(
                    transcripts[index].transcript.segments,
                    words: transcripts[index].words,
                    turns: turns
                )
                diarizedLanes.insert(track.lane)
                logger.info(
                    "Found \(Set(turns.map(\.speaker)).count) speakers in \(track.device.name, privacy: .public) in \(self.now().timeIntervalSince(started), format: .fixed(precision: 1)) s"
                )
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                logger.error(
                    "Telling speakers apart in \(track.device.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return (transcripts, diarizedLanes)
    }

    /// The note's transcript: the only track's as it is, else every track's labeled with its
    /// source and merged by time. Also returns the transcript's speakers from `diarizedLanes`,
    /// which `nameSpeakers(_:in:)` may rename.
    private func merged(
        _ transcripts: [TrackTranscript],
        of tracks: [RecordedTrack],
        diarizedLanes: Set<Int>
    ) -> (Transcript, namable: [String]) {
        guard tracks.count > 1 else {
            let transcript = transcripts.first?.transcript ?? Transcript(segments: [])
            return (transcript, diarizedLanes.isEmpty ? [] : transcript.speakers)
        }
        // A lane that switched microphones becomes one source per device, so with several
        // microphones each part is named after the device that recorded it.
        let lanes = tracks.map(\.device)
        var namable: [String] = []
        var sources: [SourceTranscript] = []
        for item in transcripts {
            let parts = Self.sources(of: item.transcript, track: item.track, among: lanes, labels: sourceLabels)
            if diarizedLanes.contains(item.track.lane) {
                for source in parts {
                    for segment in source.transcript.segments {
                        let label = TranscriptMerger.label(of: segment, in: source)
                        if !namable.contains(label) { namable.append(label) }
                    }
                }
            }
            sources += parts
        }
        let transcript = TranscriptMerger.merge(sources)
        // Echo removal may have dropped all of a label's lines.
        return (transcript, namable.filter(transcript.speakers.contains))
    }

    /// `transcript` with `speakers` renamed after what's said, where `speakerNamer` can tell, and
    /// the names by label. The note is saved either way, so a failure is only logged.
    private func nameSpeakers(
        _ speakers: [String],
        in transcript: Transcript
    ) async -> (Transcript, names: [String: String]) {
        guard let speakerNamer, !speakers.isEmpty else { return (transcript, [:]) }
        let name = speakerNamer.info.displayName
        if case .unavailable(let reason) = speakerNamer.availability {
            logger.info("Not naming speakers, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return (transcript, [:])
        }
        didChangeStage(.identifyingSpeakers)
        do {
            let names = try await speakerNamer.nameSpeakers(speakers, in: transcript)
            logger.info("Named \(names.count) of \(speakers.count) speakers")
            return (SpeakerNaming.applying(names, to: transcript), names)
        } catch {
            logger.error(
                "Naming speakers with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return (transcript, [:])
        }
    }

    /// `transcript` of `track` as one labeled source per device that recorded part of it, in order
    /// of first use. `lanes` are the first devices of all of the tracks.
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

    // MARK: - Times

    /// `spans` moved later by `offset` seconds.
    nonisolated static func shifted(
        _ spans: [Range<TimeInterval>],
        by offset: TimeInterval
    ) -> [Range<TimeInterval>] {
        spans.map { (offset + $0.lowerBound)..<(offset + $0.upperBound) }
    }
}

// Moving what a track's engine or diarizer timed from its first sample onto the note's timeline.

extension Transcript {
    /// The transcript with its times moved later by `offset` seconds.
    func shifted(by offset: TimeInterval) -> Transcript {
        var transcript = self
        for i in transcript.segments.indices {
            transcript.segments[i].start += offset
            transcript.segments[i].end += offset
        }
        return transcript
    }
}

extension LiveWord {
    /// The word moved later by `offset` seconds.
    func shifted(by offset: TimeInterval) -> LiveWord {
        LiveWord(text: text, start: start + offset, end: end + offset)
    }
}

extension SpeakerTurn {
    /// The turn moved later by `offset` seconds.
    func shifted(by offset: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(start: start + offset, end: end + offset, speaker: speaker)
    }
}

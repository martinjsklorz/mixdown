import Foundation

extension NotePipeline {
    /// What the pipeline is doing, for `RecordingCoordinator.phase`.
    enum Stage: Equatable {
        /// `progress` is 0...1 across all of the tracks.
        case transcribing(progress: Double)
        case identifyingSpeakers
        case translating
        case summarizing
    }

    /// What a note is made from.
    struct Input {
        var tracks: [RecordedTrack]
        var options: TranscriptionOptions
        /// What live sessions recognized while recording, with a source per lane; `nil` to
        /// transcribe the tracks' samples instead.
        var liveText: LiveTranscript? = nil
        /// Tells apart the people on system audio tracks; `nil` to leave them as they are.
        var diarizer: (any SpeakerDiarizer)? = nil
        var details: NoteDetails
    }

    /// What a note says besides its transcript, translation and summary.
    struct NoteDetails {
        var startedAt: Date
        var duration: TimeInterval
        var sources: [AudioInputDevice]
        var trigger: RecordingTrigger
        var isCall: Bool
        /// The app the call was in, e.g. `Zoom`; `nil` if not a call or not known.
        var callApp: String? = nil
        /// The title without a summary to name the note after; `nil` for one after the time recorded.
        var untitledName: String?
        var moments: [Moment] = []
        var talkTimeline: TalkTimeline?
        /// The recording in the `RecordingStore` the note is made from, deleted once the note is
        /// saved; `nil` if there's none.
        var recordingID: UUID?

        /// `moments` in the order of their times, each at most `duration`, as one marked as the
        /// recording stopped can be past its last sample.
        static func moments(_ moments: [Moment], upTo duration: TimeInterval) -> [Moment] {
            moments.map { Moment(id: $0.id, time: min($0.time, duration), text: $0.text) }
                .sorted { $0.time < $1.time }
        }
    }

    /// How making a note went, when it didn't fail as a whole. The note is saved, or kept to save,
    /// either way.
    struct Outcome {
        /// The tracks that couldn't be transcribed; the note has the others.
        var trackFailure: TrackFailure?
        /// Why the note has no translation, if one was asked for and translating failed.
        var translationError: (any Error)?
        /// Why the note couldn't be saved yet, if it wasn't.
        var saveError: (any Error)?

        /// Whether every track was transcribed. If not, the note's `recordingID` is left out, so
        /// saving it doesn't delete the recording.
        var isComplete: Bool { trackFailure == nil }
    }

    /// Where a device's audio begins in a track, in seconds from its first sample.
    struct DevicePart: Sendable {
        let device: AudioInputDevice
        let start: TimeInterval
    }

    /// A finished track, positioned on the note's timeline: a lane of a recording, or an
    /// imported file.
    struct RecordedTrack: Sendable {
        /// The lane's `index`, which is also its source in the live text.
        let lane: Int
        /// The device the lane started with.
        let device: AudioInputDevice
        /// Which device recorded which part; more than one if the lane switched devices.
        let parts: [DevicePart]
        /// Empty if the lane didn't keep its audio; see `Session.keepsAudio(of:transcribesLive:)`.
        let samples: [Float]
        /// When there was speech, in seconds from the track's first sample.
        let speech: [Range<TimeInterval>]
        let duration: TimeInterval
        /// Seconds from the start of the recording to the track's first sample.
        let offset: TimeInterval

        var end: TimeInterval { offset + duration }

        /// Every device that recorded a part of the track, in order.
        var devices: [AudioInputDevice] {
            parts.isEmpty ? [device] : parts.map(\.device)
        }

        /// The device recording at `time`, in seconds on the recording's timeline.
        func device(at time: TimeInterval) -> AudioInputDevice {
            parts.last { $0.start <= time - offset }?.device ?? device
        }
    }

    /// One track's transcript, on the note's timeline.
    struct TrackTranscript {
        let track: RecordedTrack
        var transcript: Transcript
        /// Per segment, its words with their times, if the engine timed them.
        var words: [[LiveWord]]?

        init(track: RecordedTrack, transcript: Transcript, words: [[LiveWord]]? = nil) {
            self.track = track
            self.transcript = transcript
            self.words = words
        }

        /// What `liveText` recognized from input `source`, the live session of `track`, moved onto
        /// the note's timeline.
        init(liveText: LiveTranscript, source: Int, track: RecordedTrack, language: String?) {
            self.track = track
            transcript = Transcript(segments: liveText.segments(fromSource: source), language: language)
                .shifted(by: track.offset)
            words = liveText.words(fromSource: source).map { words in words.map { $0.shifted(by: track.offset) } }
        }
    }

    /// Tracks that couldn't be transcribed, and why the first of them failed.
    struct TrackFailure {
        /// Every device that recorded a part of the failed tracks.
        let devices: [AudioInputDevice]
        let error: any Error
    }

    /// Combines the progress of the tracks being transcribed, each weighted by its length. The
    /// engines transcribe them one after another, at a pace that depends on how much speech each
    /// has.
    struct TranscriptionProgress {
        let id = UUID()
        let sampleCounts: [Int]
        var fractions: [Double]

        init(sampleCounts: [Int]) {
            self.sampleCounts = sampleCounts
            fractions = Array(repeating: 0, count: sampleCounts.count)
        }

        var total: Double {
            let samples = Double(sampleCounts.reduce(0, +))
            guard samples > 0 else { return 0 }
            return zip(sampleCounts, fractions).reduce(0) { $0 + Double($1.0) * $1.1 } / samples
        }
    }
}

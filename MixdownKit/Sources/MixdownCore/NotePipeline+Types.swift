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
        /// The title without a summary to name the note after; `nil` for one after the time recorded.
        var untitledName: String?
        var moments: [Moment] = []
        var talkTimeline: TalkTimeline?
        /// The recording in the `RecordingStore` the note is made from, deleted once the note is
        /// saved; `nil` if there's none.
        var recordingID: UUID?
    }

    /// How making a note went, when it didn't fail as a whole.
    struct Outcome {
        /// What to tell the user about, e.g. a track that couldn't be transcribed or a translation
        /// that failed.
        var messages: [String]
        /// Whether every track was transcribed. If not, the note's `recordingID` is left out, so
        /// saving it doesn't delete the recording.
        var isComplete: Bool
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

import Foundation

extension RecordingCoordinator {
    /// One recording from start to stop, across all of its inputs. A class, as its inputs change
    /// while it runs.
    @MainActor
    final class Session {
        let id = UUID()
        let startedAt: Date
        /// `options` as the recording started, used to transcribe all of it.
        let options: TranscriptionOptions
        /// The system audio, for the microphones to take its echo out; `nil` without echo
        /// cancellation.
        let echoReference: EchoReference?
        /// `measuresTalkTime` as the recording started.
        let measuresTalkTime: Bool
        /// `speakerDiarizer` as the recording started.
        let diarizer: (any SpeakerDiarizer)?
        /// Whether the recording was started for a call, from a notification or automatically.
        var isCall = false
        var trigger = RecordingTrigger.manual
        private(set) var lanes: [Lane] = []
        /// Devices that went away or failed to start during this recording. They aren't picked
        /// again until they leave the device list or the user chooses them.
        var unavailableDeviceIDs: Set<String> = []
        /// Why an input last stopped on its own; reported if no input is left.
        var lastCaptureError: (any Error)?
        /// Whether `syncCaptures(of:)` is running, and whether it should go around once more.
        var isSyncing = false
        var needsSync = false
        /// Inputs whose device went away and that are waiting for the system to pick a new
        /// default. The recording doesn't end for lack of inputs while there are any.
        var pendingReplacements = 0
        /// When the recording was paused, on the host clock; `nil` unless paused, or resumed and
        /// waiting for its first input to start again.
        var pausedAt: TimeInterval?
        /// Whether the recording is paused. No input starts while it is.
        var isPaused = false
        /// Stops the inputs for a pause; resuming waits for it.
        var pausing: Task<Void, Never>?
        /// The time spent paused so far, on the host clock. Taken off the host time of everything
        /// captured afterwards, which leaves the pauses out of the tracks.
        var pausedDuration: TimeInterval = 0

        init(
            startedAt: Date,
            options: TranscriptionOptions,
            echoReference: EchoReference?,
            measuresTalkTime: Bool,
            diarizer: (any SpeakerDiarizer)?
        ) {
            self.startedAt = startedAt
            self.options = options
            self.echoReference = echoReference
            self.measuresTalkTime = measuresTalkTime
            self.diarizer = diarizer
        }

        /// Whether a lane of `kind` keeps its audio: always for an offline engine, which transcribes
        /// it once the recording ends, and for system audio whose speakers are told apart then.
        func keepsAudio(of kind: AudioSourceKind, transcribesLive: Bool) -> Bool {
            !transcribesLive || (diarizer != nil && kind == .systemAudio)
        }

        /// The devices recording right now.
        var activeDevices: [AudioInputDevice] { lanes.compactMap(\.current?.device) }

        /// Every device recorded from, in the order they were first used.
        var devices: [AudioInputDevice] {
            var seen = Set<String>()
            return lanes.flatMap { $0.captures.map(\.device) }.filter { seen.insert($0.id).inserted }
        }

        func addLane(kind: AudioSourceKind) -> Lane {
            let lane = Lane(kind: kind, index: lanes.count)
            lanes.append(lane)
            return lane
        }

        /// Removes and returns the captures recording right now. Their streams ending afterwards
        /// isn't taken for their devices going away, as they're no longer current.
        func takeCurrentCaptures() -> [Capture] {
            let current = lanes.compactMap(\.current)
            for lane in lanes {
                lane.current = nil
            }
            return current
        }
    }

    /// One input of a session, such as "the microphone", recorded into a single track. Its device
    /// can change mid-recording; each device it used has a capture of its own.
    @MainActor
    final class Lane {
        let kind: AudioSourceKind
        /// Position in the session's lanes, which is also the lane's source in `liveTranscript`.
        let index: Int
        /// Every capture of the lane, the current one last.
        private(set) var captures: [Capture] = []
        /// The capture recording right now. `nil` while switching devices, after the device went
        /// away, or once the input is turned off.
        var current: Capture?

        init(kind: AudioSourceKind, index: Int) {
            self.kind = kind
            self.index = index
        }

        /// The device the lane started with. The transcript names each part by the device that
        /// recorded it.
        var firstDevice: AudioInputDevice? { captures.first?.device }

        func add(_ capture: Capture) {
            captures.append(capture)
            current = capture
        }
    }

    /// One capture of a device, from start to stop.
    struct Capture: Sendable {
        let id = UUID()
        let device: AudioInputDevice
        let capture: any AudioCapturing
        /// Drains the capture stream off the main actor and returns the track.
        let consumer: Task<CaptureResult, Never>
        /// Feeds the audio to a live session, if the engine transcribes live. Returns the error
        /// that stopped it early, if any.
        let live: Task<(any Error)?, Never>?
    }

    /// Audio a consumer is handing to the live session.
    struct LiveFeed: Sendable {
        let samples: [Float]
        /// The capture's `startHostTime`, which the session's times count from.
        let startHostTime: TimeInterval?
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    struct CaptureResult: Sendable {
        var track: AudioTrack
        /// When there was speech, in seconds from the track's first sample.
        var speech: [Range<TimeInterval>] = []
        var error: (any Error)?
    }

    /// A lane's captures joined into one track, and where in it each device's audio begins.
    struct LaneAudio: Sendable {
        var track: AudioTrack
        var parts: [DevicePart] = []
        /// When there was speech, in seconds from the track's first sample.
        var speech: [Range<TimeInterval>] = []
    }

    /// Where a device's audio begins in a lane's track, in seconds from its first sample.
    struct DevicePart: Sendable {
        let device: AudioInputDevice
        let start: TimeInterval
    }

    /// A finished lane's audio, positioned on the recording's timeline.
    struct RecordedTrack: Sendable {
        /// The lane's `index`.
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

    /// Combines the progress of a recording's tracks, each weighted by its length. The engines
    /// transcribe them one after another, at a pace that depends on how much speech each has.
    struct TranscriptionProgress {
        let sessionID: UUID
        let sampleCounts: [Int]
        var fractions: [Double]

        init(sessionID: UUID, tracks: [RecordedTrack]) {
            self.sessionID = sessionID
            sampleCounts = tracks.map(\.samples.count)
            fractions = Array(repeating: 0, count: tracks.count)
        }

        var total: Double {
            let samples = Double(sampleCounts.reduce(0, +))
            guard samples > 0 else { return 0 }
            return zip(sampleCounts, fractions).reduce(0) { $0 + Double($1.0) * $1.1 } / samples
        }
    }

    typealias CaptureStream = AsyncThrowingStream<AudioChunk, any Error>

    struct StartedCapture {
        let device: AudioInputDevice
        let capture: any AudioCapturing
        let stream: CaptureStream
    }

    /// One track's transcript, on the recording's timeline.
    struct TrackTranscript {
        let track: RecordedTrack
        var transcript: Transcript
        /// Per segment, its words with their times, if the engine timed them.
        var words: [[LiveWord]]?
    }

    /// Tracks of a recording that couldn't be transcribed, and why the first of them failed.
    struct TrackFailure {
        /// Every device that recorded a part of the failed tracks.
        let devices: [AudioInputDevice]
        let error: any Error
    }
}

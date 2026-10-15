import Foundation
import MixdownCore
import Testing

struct AudioCueTests {
    private let started = RecordingCoordinator.Phase.recording(startedAt: Fixtures.startDate)

    @Test func startingAndStoppingAreCued() {
        #expect(AudioCue.cue(from: .idle, to: started) == .recordingStarted)
        #expect(AudioCue.cue(from: .failed(message: "Old error"), to: started) == .recordingStarted)
        #expect(AudioCue.cue(from: started, to: .transcribing(progress: 0)) == .recordingStopped)
        // A recording too short to transcribe.
        #expect(AudioCue.cue(from: started, to: .idle) == .recordingStopped)
    }

    @Test func errorsAreCued() {
        // Starting failed, e.g. without microphone permission.
        #expect(AudioCue.cue(from: .idle, to: .failed(message: "Denied")) == .failed)
        // Capture ended with an error before anything was saved.
        #expect(AudioCue.cue(from: started, to: .failed(message: "Unplugged")) == .failed)
        #expect(AudioCue.cue(from: .transcribing(progress: 0.5), to: .failed(message: "Boom")) == .failed)
        #expect(AudioCue.cue(from: .preparingModel(progress: 0.5), to: .failed(message: "Offline")) == .failed)
        #expect(AudioCue.cue(from: .failed(message: "Denied"), to: .failed(message: "Unplugged")) == .failed)
    }

    @Test func otherChangesAreSilent() {
        #expect(AudioCue.cue(from: .idle, to: .idle) == nil)
        #expect(AudioCue.cue(from: started, to: started) == nil)
        #expect(AudioCue.cue(from: .failed(message: "Denied"), to: .failed(message: "Denied")) == nil)
        #expect(AudioCue.cue(from: .idle, to: .preparingModel(progress: 0)) == nil)
        #expect(AudioCue.cue(from: .preparingModel(progress: 0.2), to: .preparingModel(progress: 0.4)) == nil)
        #expect(AudioCue.cue(from: .transcribing(progress: 0.2), to: .transcribing(progress: 0.4)) == nil)
        // The note itself is cued when it's written.
        #expect(AudioCue.cue(from: .transcribing(progress: 1), to: .idle) == nil)
        #expect(AudioCue.cue(from: .failed(message: "Denied"), to: .idle) == nil)
    }
}

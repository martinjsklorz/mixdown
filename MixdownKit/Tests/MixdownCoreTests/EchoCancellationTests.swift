import Foundation
import Testing

@testable import MixdownCore

/// Subtracts the reference from the microphone, `latency` samples late, and throws on frame
/// `failingFrame` if set.
final class SubtractingEchoCanceller: EchoCanceller, @unchecked Sendable {
    let frameSize = 256
    let latency = 256
    private let failingFrame: Int?
    private var previous: [Float]
    private(set) var frameCount = 0
    private(set) var resetCount = 0

    struct Failure: Error {}

    init(failingFrame: Int? = nil) {
        self.failingFrame = failingFrame
        previous = Array(repeating: 0, count: 256)
    }

    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        defer { frameCount += 1 }
        if frameCount == failingFrame { throw Failure() }
        let output = previous
        previous = zip(microphone, reference).map { $0 - $1 }
        return output
    }

    func reset() {
        resetCount += 1
        previous = Array(repeating: 0, count: 256)
    }
}

/// Hands out a new `SubtractingEchoCanceller` whenever asked.
final class SubtractingEchoCancellation: EchoCancellation {
    private let prepareCalls = LockedValue(0)

    var prepareCount: Int { prepareCalls.current }

    func prepare() {
        prepareCalls.update { $0 += 1 }
    }

    func takeCanceller() -> (any EchoCanceller)? {
        SubtractingEchoCanceller()
    }
}

enum EchoFixtures {
    /// A second of system audio that doesn't repeat within a frame.
    static let systemAudio: [Float] = (0..<16_000).map { Float(sin(Double($0) * 0.05) * 0.5) }

    /// `seconds` of a steady voice plus the echo of `systemAudio` as `EchoRemover` expects it:
    /// `referenceLead` before the system audio's timestamps, for a microphone starting `offset`
    /// seconds after it.
    static func microphone(voice: Float, offset: TimeInterval = 0, count: Int = 16_000) -> [Float] {
        let start = Int(offset * AudioChunk.sampleRate) + EchoRemover.referenceLead
        return (0..<count).map { index in
            let echoIndex = start + index
            return voice + (systemAudio.indices.contains(echoIndex) ? systemAudio[echoIndex] : 0)
        }
    }

    /// `samples` in pieces of `size`, which doesn't divide a frame.
    static func pieces(of samples: [Float], size: Int = 100) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }
}

struct EchoRemoverTests {
    private func activeReference(startingAt hostTime: TimeInterval = 100) -> EchoReference {
        let reference = EchoReference()
        reference.beginWriting()
        reference.write(AudioChunk(samples: EchoFixtures.systemAudio, hostTime: hostTime))
        return reference
    }

    private func expectVoice(_ samples: [Float], _ voice: Float, sourceLocation: SourceLocation = #_sourceLocation) {
        let worst = samples.map { abs($0 - voice) }.max() ?? 0
        #expect(worst < 0.0001, "off by up to \(worst)", sourceLocation: sourceLocation)
    }

    @Test func removesTheEchoLinedUpByHostTimeAndReturnsEverySample() {
        // The microphone starts half a second after the system audio.
        let reference = activeReference(startingAt: 100)
        let input = EchoFixtures.microphone(voice: 0.25, offset: 0.5, count: 8_000)
        let remover = EchoRemover(canceller: SubtractingEchoCanceller(), reference: reference, startHostTime: 100.5)

        var output: [Float] = []
        for piece in EchoFixtures.pieces(of: input) {
            output += remover.process(piece)
        }
        output += remover.finish()

        #expect(output.count == input.count)
        expectVoice(output, 0.25)
    }

    @Test func holdsMicrophoneAudioUntilItsSystemAudioArrives() {
        let reference = EchoReference()
        reference.beginWriting()
        let input = EchoFixtures.microphone(voice: 0.25, count: 4_000)
        let remover = EchoRemover(canceller: SubtractingEchoCanceller(), reference: reference, startHostTime: 100)

        #expect(remover.process(input).isEmpty)

        reference.write(AudioChunk(samples: EchoFixtures.systemAudio, hostTime: 100))
        var output = remover.process([])
        output += remover.finish()

        #expect(output.count == input.count)
        expectVoice(output, 0.25)
    }

    @Test func stopsWaitingForSystemAudioThatDoesNotCome() {
        let reference = EchoReference()
        reference.beginWriting()
        let input = [Float](repeating: 0.25, count: EchoRemover.maximumWait + EchoRemover.referenceLead + 1_000)
        let remover = EchoRemover(canceller: SubtractingEchoCanceller(), reference: reference, startHostTime: 100)

        let output = remover.process(input)

        #expect(!output.isEmpty)
        expectVoice(output, 0.25)
    }

    @Test func doesNotWaitWhileSystemAudioIsNotRecording() {
        let remover = EchoRemover(canceller: SubtractingEchoCanceller(), reference: EchoReference(), startHostTime: 100)

        let output = remover.process([Float](repeating: 0.25, count: 1_024))

        // All but the canceller's latency.
        #expect(output.count == 1_024 - 256)
        expectVoice(output, 0.25)
    }

    @Test func passesTheRestThroughOnceTheCancellerFails() {
        let reference = activeReference()
        let input = EchoFixtures.microphone(voice: 0.25, count: 4_000)
        let remover = EchoRemover(
            canceller: SubtractingEchoCanceller(failingFrame: 4),
            reference: reference,
            startHostTime: 100
        )

        var output: [Float] = []
        for piece in EchoFixtures.pieces(of: input) {
            output += remover.process(piece)
        }
        output += remover.finish()

        #expect(output == Array(output.prefix(3 * 256)) + Array(input[(3 * 256)...]))
        expectVoice(Array(output.prefix(3 * 256)), 0.25)
    }
}

struct EchoReferenceTests {
    @Test func fillsGapsWithSilenceAndForgetsOldAudio() {
        let reference = EchoReference()
        reference.write(AudioChunk(samples: [1, 1], hostTime: 10))
        // One second later: a gap of a second minus two samples.
        reference.write(AudioChunk(samples: [2], hostTime: 11))

        #expect(reference.state.startHostTime == 10)
        #expect(reference.state.count == 16_001)
        #expect(reference.read(from: -1, count: 4) == [0, 1, 1, 0])
        #expect(reference.read(from: 15_999, count: 3) == [0, 2, 0])

        reference.write(AudioChunk(samples: [Float](repeating: 3, count: EchoReference.capacity)))
        #expect(reference.read(from: 16_000, count: 2) == [0, 3])
    }

    @Test func isActiveWhileWritten() {
        let reference = EchoReference()
        #expect(!reference.state.isActive)
        reference.beginWriting()
        #expect(reference.state.isActive)
        reference.endWriting()
        #expect(!reference.state.isActive)
    }
}

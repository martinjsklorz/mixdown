import Testing

@testable import MixdownCore

struct InputLevelTests {
    @Test func meterSpansSixtyDecibels() {
        #expect(InputLevel(peak: 1).meterValue == 1)
        #expect(abs(InputLevel(peak: 0.1).meterValue - 2.0 / 3) < 1e-6)
        #expect(InputLevel(peak: 0.001).meterValue < 1e-6)
        #expect(InputLevel(peak: 0.0001).meterValue == 0)
        #expect(InputLevel(peak: 0).meterValue == 0)
        #expect(InputLevel(peak: 2).meterValue == 1)
    }

    @Test func silenceIsNearDigitalZero() {
        #expect(InputLevel(peak: 0).isSilent)
        #expect(InputLevel(peak: 0.00005).isSilent)
        #expect(!InputLevel(peak: 0.001).isSilent)
    }

    @Test func meterReportsPeakOncePerInterval() {
        var meter = LevelMeter()
        #expect(meter.add(chunk(seconds: 0.05, samples: [0.2, -0.5])) == nil)
        #expect(meter.add(chunk(seconds: 0.05, samples: [0.3])) == InputLevel(peak: 0.5))
        // The next interval starts from scratch.
        #expect(meter.add(chunk(seconds: 0.1, samples: [0.1])) == InputLevel(peak: 0.1))
    }

    /// `seconds` of audio whose first samples are `samples`, the rest silence.
    private func chunk(seconds: Double, samples: [Float]) -> AudioChunk {
        let count = Int(seconds * AudioChunk.sampleRate)
        return AudioChunk(samples: samples + Array(repeating: 0, count: count - samples.count))
    }
}

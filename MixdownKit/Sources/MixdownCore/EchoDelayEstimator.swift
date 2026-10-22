import Foundation

/// Finds how much later the microphone hears the system audio than its timestamps say, either way
/// and up to a second: the speakers' and microphone's latency (Bluetooth adds a lot) plus however
/// far the two inputs' timestamps disagree.
///
/// Cross-correlates windows of both with GCC-PHAT, adding up the evidence of past windows with a
/// decay so the estimate can follow a change. Works on audio averaged down to 4 kHz, plenty for
/// timing an echo, so it stays cheap.
struct EchoDelayEstimator {
    struct Estimate: Equatable {
        /// How many samples (at `AudioChunk.sampleRate`) after the system audio the microphone
        /// hears it; negative if before.
        var delay: Int
        /// How far the correlation peak stands out from the rest; above `confidenceThreshold`.
        var confidence: Float
    }

    /// Samples per window, at `AudioChunk.sampleRate` (about 2 s).
    static let windowSize = 32_768
    /// Samples between windows (0.5 s).
    static let hop = 8_000
    /// The largest delay looked for either way, in samples (1 s).
    static let maximumDelay = 16_000
    /// How much of the past evidence each new window keeps (a few seconds' worth).
    static let decay: Float = 0.85
    /// Windows whose system audio is this much quieter than the loudest so far say little about
    /// the echo, so they're skipped. As LocalVQE does.
    static let gateDecibels: Float = 26
    /// How far the peak must stand out from the average correlation to count.
    static let confidenceThreshold: Float = 8

    private static let decimation = 4
    private static let fftSize = 2 * windowSize / decimation

    private let fft = FFT(size: fftSize)
    private var sumReal: [Float]
    private var sumImaginary: [Float]
    private var loudestReference: Float = 0

    init() {
        sumReal = Array(repeating: 0, count: Self.fftSize)
        sumImaginary = Array(repeating: 0, count: Self.fftSize)
    }

    /// Adds a window of `windowSize` microphone samples and the system audio stamped with the same
    /// times. Returns the delay once it stands out, `nil` while it doesn't or the window was
    /// skipped.
    mutating func add(microphone: [Float], reference: [Float]) -> Estimate? {
        precondition(microphone.count == Self.windowSize && reference.count == Self.windowSize)
        let referenceLevel = Self.rms(reference)
        loudestReference = max(loudestReference, referenceLevel)
        guard referenceLevel > InputLevel.silenceThreshold,
            referenceLevel > loudestReference * pow(10, -Self.gateDecibels / 20),
            Self.rms(microphone) > InputLevel.silenceThreshold
        else { return nil }

        let (microphoneReal, microphoneImaginary) = spectrum(of: microphone)
        let (referenceReal, referenceImaginary) = spectrum(of: reference)
        for bin in 0..<Self.fftSize {
            // The microphone's spectrum times the reference's conjugate, whitened (PHAT), so every
            // frequency has the same say and the peak is sharp.
            let real = microphoneReal[bin] * referenceReal[bin] + microphoneImaginary[bin] * referenceImaginary[bin]
            let imaginary =
                microphoneImaginary[bin] * referenceReal[bin] - microphoneReal[bin] * referenceImaginary[bin]
            let magnitude = (real * real + imaginary * imaginary).squareRoot() + 1e-9
            sumReal[bin] = sumReal[bin] * Self.decay + real / magnitude
            sumImaginary[bin] = sumImaginary[bin] * Self.decay + imaginary / magnitude
        }

        // The inverse transform as the conjugate of the forward one; only the real part counts.
        var correlation = sumReal
        var imaginary = sumImaginary.map { -$0 }
        fft.transform(&correlation, &imaginary)

        // Index `lag` holds lag `lag`, and `fftSize - lag` lag `-lag`.
        let maximumLag = Self.maximumDelay / Self.decimation
        var bestLag = 0
        var peak = -Float.infinity
        var total: Float = 0
        for lag in -maximumLag...maximumLag {
            let value = correlation[(lag + Self.fftSize) % Self.fftSize]
            total += abs(value)
            if value > peak {
                peak = value
                bestLag = lag
            }
        }
        let confidence = peak / (total / Float(2 * maximumLag + 1) + 1e-12)
        guard confidence > Self.confidenceThreshold else { return nil }
        return Estimate(delay: bestLag * Self.decimation, confidence: confidence)
    }

    /// The spectrum of `samples` averaged down by `decimation`, zero-padded to `fftSize` so the
    /// correlation doesn't wrap around.
    private func spectrum(of samples: [Float]) -> (real: [Float], imaginary: [Float]) {
        var real = [Float](repeating: 0, count: Self.fftSize)
        for index in 0..<(Self.windowSize / Self.decimation) {
            let first = index * Self.decimation
            var sum: Float = 0
            for offset in 0..<Self.decimation { sum += samples[first + offset] }
            real[index] = sum / Float(Self.decimation)
        }
        var imaginary = [Float](repeating: 0, count: Self.fftSize)
        fft.transform(&real, &imaginary)
        return (real, imaginary)
    }

    private static func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }
}

/// An in-place radix-2 FFT, forward and unscaled, of a fixed power-of-two size.
struct FFT {
    let size: Int
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosines = (0..<(size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sines = (0..<(size / 2)).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { index in
            var result = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { result |= 1 << (bits - 1 - bit) }
            return result
        }
    }

    func transform(_ real: inout [Float], _ imaginary: inout [Float]) {
        precondition(real.count == size && imaginary.count == size)
        for index in 0..<size where index < reversed[index] {
            real.swapAt(index, reversed[index])
            imaginary.swapAt(index, reversed[index])
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for offset in 0..<half {
                    let cosine = cosines[offset * step]
                    let sine = sines[offset * step]
                    let even = start + offset
                    let odd = even + half
                    let oddReal = real[odd] * cosine - imaginary[odd] * sine
                    let oddImaginary = real[odd] * sine + imaginary[odd] * cosine
                    real[odd] = real[even] - oddReal
                    imaginary[odd] = imaginary[even] - oddImaginary
                    real[even] += oddReal
                    imaginary[even] += oddImaginary
                }
                start += length
            }
            length *= 2
        }
    }
}

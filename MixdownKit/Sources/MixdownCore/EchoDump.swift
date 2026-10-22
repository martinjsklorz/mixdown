import Foundation
import os

/// Debug builds only: saves what an `EchoRemover` hands its canceller and gets back, as three
/// 16 kHz WAV files, frame for frame, to study the echo offline. Off unless turned on with
/// `defaults write app.mixdown.Mixdown dumpsEchoAudio -bool true`; it records the user's calls.
///
/// - `microphone.wav`: the microphone as given to the canceller.
/// - `system-audio.wav`: the system audio paired with it, `EchoRemover.lead` ahead.
/// - `cleaned.wav`: what the canceller returned, `EchoCanceller.latency` samples late.
final class EchoDump {
    static let defaultsKey = "dumpsEchoAudio"

    private let directory: URL
    private let files: [FileHandle]
    private var sampleCount = 0
    private let logger = Logger(subsystem: "app.mixdown", category: "echo")

    /// A new dump in its own directory, if turned on and the files could be created.
    static func startIfEnabled() -> EchoDump? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-\(stamp)")
        do {
            return try EchoDump(directory: directory)
        } catch {
            Logger(subsystem: "app.mixdown", category: "echo")
                .error("Couldn't save echo audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = try ["microphone", "system-audio", "cleaned"].map { name in
            let url = directory.appendingPathComponent("\(name).wav")
            FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleCount: 0))
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            return file
        }
        logger.info("Saving echo audio to \(directory.path, privacy: .public)")
    }

    func write(microphone: [Float], systemAudio: [Float], cleaned: [Float]) {
        for (file, samples) in zip(files, [microphone, systemAudio, cleaned]) {
            samples.withUnsafeBytes { try? file.write(contentsOf: Data($0)) }
        }
        sampleCount += microphone.count
    }

    /// Fills in the headers' sizes and closes the files.
    func finish() {
        for file in files {
            try? file.seek(toOffset: 0)
            try? file.write(contentsOf: Self.header(sampleCount: sampleCount))
            try? file.close()
        }
        logger.info("Saved echo audio to \(self.directory.path, privacy: .public)")
    }

    /// A mono 32-bit float WAV header for `sampleCount` samples at `AudioChunk.sampleRate`.
    private static func header(sampleCount: Int) -> Data {
        let rate = UInt32(AudioChunk.sampleRate)
        let dataSize = UInt32(sampleCount * 4)
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(3))  // IEEE float
        append(UInt16(1))
        append(rate)
        append(rate * 4)
        append(UInt16(4))
        append(UInt16(32))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        return data
    }
}

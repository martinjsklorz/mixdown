import Foundation
import os

/// A recording Mixdown kept because no note was made of it: Mixdown quit or crashed while it was
/// recorded or transcribed, or transcribing it failed. `RecordingCoordinator.transcribe(_:)` makes
/// a note of it, `RecordingCoordinator.discard(_:)` deletes it.
///
/// One that isn't on disk, recorded without `RecordingCoordinator.keepsAudioOnDisk`, is only kept
/// until Mixdown quits.
public struct UnfinishedRecording: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    /// Seconds recorded, not counting pauses.
    public let duration: TimeInterval
    /// Every input that was recorded, in the order they were first used.
    public let sources: [AudioInputDevice]
    /// Whether its audio is in the `RecordingStore`, rather than in memory.
    public let isOnDisk: Bool
}

/// Unfinished recordings only kept in memory, with their audio, handed from one
/// `RecordingCoordinator` to the next. See `RecordingCoordinator.takeRecordingsInMemory()`.
public struct RecordingsInMemory {
    var recordings: [(recording: UnfinishedRecording, audio: RecordingStore.StoredRecording)] = []

    public init() {}

    init(recordings: [(recording: UnfinishedRecording, audio: RecordingStore.StoredRecording)]) {
        self.recordings = recordings
    }
}

/// Keeps the audio of each recording on disk while it's recorded and until its note is saved, so
/// quitting, a crash or a failed transcription doesn't lose it.
///
/// Each recording is a folder named after its ID, with a `recording.json` describing it, and an
/// audio file per capture, which `CaptureLoop` appends to as it records. The description is
/// written again whenever it changes, e.g. as an input switches devices or a moment is marked.
public struct RecordingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Mixdown/Recordings`, inside the container when sandboxed. `nil` if
    /// there's no Application Support directory.
    public static var `default`: RecordingStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            RecordingStore(directory: $0.appendingPathComponent("Mixdown/Recordings", isDirectory: true))
        }
    }

    private static let logger = Logger(subsystem: "app.mixdown", category: "recordings")

    /// What a recording is, besides its audio.
    struct Description: Codable, Equatable {
        struct Device: Codable, Equatable {
            var id: String
            var name: String
            var kind: String
        }

        /// An input of the recording, with the device of each of its captures, in order.
        struct Lane: Codable, Equatable {
            var kind: String
            var captures: [Device]
        }

        struct Mark: Codable, Equatable {
            var id: UUID
            var time: TimeInterval
            var text: String
        }

        var startedAt: Date
        var language: String?
        var trigger: String
        var isCall: Bool
        var lanes: [Lane]
        var moments: [Mark]
    }

    /// A recording read back from disk: its description and each lane's audio, with the device the
    /// lane started with.
    struct StoredRecording {
        let description: Description
        let lanes: [(device: AudioInputDevice, audio: RecordingCoordinator.LaneAudio)]
    }

    // MARK: Writing

    /// Writes `description` for the recording `id`, creating its folder if need be.
    func save(_ description: Description, of id: UUID) throws {
        let folder = folder(of: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(description).write(to: folder.appendingPathComponent("recording.json"), options: .atomic)
    }

    /// Where the audio of capture `capture` of lane `lane` of the recording `id` goes.
    func audioURL(of id: UUID, lane: Int, capture: Int) -> URL {
        folder(of: id).appendingPathComponent("\(lane)-\(capture).audio")
    }

    /// Deletes the recording `id`, if there is one.
    public func delete(_ id: UUID) {
        let folder = folder(of: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Self.logger.error("Deleting a recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Reading

    /// Every recording in the store, oldest first, judged by their descriptions and the lengths of
    /// their audio files, without reading the audio. Folders without a description, from a
    /// recording that never got under way, are deleted.
    func recordings() -> [UnfinishedRecording] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> UnfinishedRecording? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            guard let description = try? description(of: id) else {
                delete(id)
                return nil
            }
            let tracks = description.lanes.indices.map { lane in
                var track = AudioTrack(keepsSamples: false)
                for capture in description.lanes[lane].captures.indices {
                    let url = audioURL(of: id, lane: lane, capture: capture)
                    guard let header = CaptureAudioFile.header(of: url) else { continue }
                    track.append(AudioTrack(sampleCount: header.sampleCount, startHostTime: header.startHostTime))
                }
                return track
            }
            let duration = zip(tracks, AudioTrack.startOffsets(of: tracks)).map { $0.duration + $1 }.max() ?? 0
            return UnfinishedRecording(
                id: id,
                startedAt: description.startedAt,
                duration: duration,
                sources: description.sources,
                isOnDisk: true
            )
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Reads the recording `id`, its audio included, with each lane's captures joined into one
    /// track like `RecordingCoordinator` joins them when a recording ends. Captures without audio
    /// are left out, and lanes without captures.
    func load(_ id: UUID) throws -> StoredRecording {
        let description = try description(of: id)
        var lanes: [(device: AudioInputDevice, audio: RecordingCoordinator.LaneAudio)] = []
        for (index, lane) in description.lanes.enumerated() {
            guard let first = lane.captures.first else { continue }
            var audio = RecordingCoordinator.LaneAudio(track: AudioTrack())
            for (capture, device) in lane.captures.enumerated() {
                let url = audioURL(of: id, lane: index, capture: capture)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                audio.append(try CaptureAudioFile.read(url), from: device.audioInputDevice, speech: [])
            }
            lanes.append((first.audioInputDevice, audio))
        }
        return StoredRecording(description: description, lanes: lanes)
    }

    private func description(of id: UUID) throws -> Description {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folder(of: id).appendingPathComponent("recording.json"))
        return try decoder.decode(Description.self, from: data)
    }

    private func folder(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

extension RecordingStore.Description {
    /// Every device recorded from, in the order they were first used.
    var sources: [AudioInputDevice] {
        var seen = Set<String>()
        return lanes.flatMap(\.captures).map(\.audioInputDevice).filter { seen.insert($0.id).inserted }
    }

    var recordingTrigger: RecordingTrigger { RecordingTrigger(rawValue: trigger) ?? .manual }

    var recordedMoments: [Moment] {
        moments.map { Moment(id: $0.id, time: $0.time, text: $0.text) }
    }
}

extension RecordingStore.Description.Device {
    init(_ device: AudioInputDevice) {
        self.init(id: device.id, name: device.name, kind: device.kind.rawValue)
    }

    var audioInputDevice: AudioInputDevice {
        AudioInputDevice(id: id, name: name, kind: AudioSourceKind(rawValue: kind) ?? .microphone)
    }
}

/// One capture's audio file: an 8-byte tag, the host time of its first sample as a little-endian
/// Float64 (NaN for none), then the samples as Float32 in the Mac's byte order.
enum CaptureAudioFile {
    static let tag = Array("MXDAUD01".utf8)
    static let headerSize = 16

    static func header(startHostTime: TimeInterval?) -> Data {
        var data = Data(tag)
        withUnsafeBytes(of: (startHostTime ?? .nan).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// The host time of the file's first sample and how many samples it has, from its header and
    /// size; `nil` if it isn't a capture's audio file.
    static func header(of url: URL) -> (startHostTime: TimeInterval?, sampleCount: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerSize),
            let size = try? handle.seekToEnd(),
            let startHostTime = startHostTime(in: header)
        else { return nil }
        return (startHostTime, (Int(size) - headerSize) / MemoryLayout<Float>.size)
    }

    /// The file's audio as a track. A sample cut off by a crash is left out.
    static func read(_ url: URL) throws -> AudioTrack {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let startHostTime = startHostTime(in: data) else { throw CocoaError(.fileReadCorruptFile) }
        let count = (data.count - headerSize) / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { samples in
            data.copyBytes(to: samples, from: headerSize..<(headerSize + count * MemoryLayout<Float>.size))
        }
        return AudioTrack(samples: samples, startHostTime: startHostTime)
    }

    /// The host time in `header`, `.some(nil)` for none; `nil` if it isn't a header.
    private static func startHostTime(in header: Data) -> TimeInterval?? {
        guard header.count >= headerSize, Array(header.prefix(tag.count)) == tag else { return nil }
        let bits = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: tag.count, as: UInt64.self) }
        let time = TimeInterval(bitPattern: UInt64(littleEndian: bits))
        return .some(time.isNaN ? nil : time)
    }
}

/// Appends a capture's audio to its file as it's recorded. Writing stops at the first error,
/// leaving what was written; the recording goes on, only without its audio on disk.
final class CaptureAudioWriter {
    private let url: URL
    private var handle: FileHandle?
    private var failed = false
    private static let logger = Logger(subsystem: "app.mixdown", category: "recordings")

    init(url: URL) {
        self.url = url
    }

    /// Writes `samples` after those written before. The first call creates the file, with
    /// `startHostTime` as the host time of its first sample.
    func write(_ samples: [Float], startHostTime: TimeInterval?) {
        guard !failed, !samples.isEmpty else { return }
        do {
            if handle == nil {
                let header = CaptureAudioFile.header(startHostTime: startHostTime)
                guard FileManager.default.createFile(atPath: url.path, contents: header) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                self.handle = handle
            }
            try handle?.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
        } catch {
            failed = true
            close()
            Self.logger.error("Keeping the audio on disk failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

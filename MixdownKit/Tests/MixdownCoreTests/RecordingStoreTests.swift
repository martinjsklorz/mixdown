import Foundation
import Testing

@testable import MixdownCore

struct RecordingStoreTests {
    /// A store in a folder of its own, deleted by `remove(_:)`.
    static func makeStore() -> RecordingStore {
        RecordingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    static func remove(_ store: RecordingStore) {
        try? FileManager.default.removeItem(at: store.directory)
    }

    private func description(lanes: [RecordingStore.Description.Lane]) -> RecordingStore.Description {
        RecordingStore.Description(
            startedAt: Fixtures.startDate,
            language: "de",
            trigger: RecordingTrigger.automatic.rawValue,
            isCall: true,
            lanes: lanes,
            moments: [RecordingStore.Description.Mark(id: UUID(), time: 1, text: "Budget")]
        )
    }

    private func write(_ chunks: [AudioChunk], to url: URL) {
        let writer = CaptureAudioWriter(url: url)
        var track = AudioTrack(keepsSamples: false)
        for chunk in chunks {
            track.append(chunk)
            writer.write(chunk.samples, startHostTime: track.startHostTime)
        }
        writer.close()
    }

    @Test func listsAndLoadsRecordingsWithEachLanesCapturesJoined() throws {
        let store = Self.makeStore()
        defer { Self.remove(store) }
        let id = UUID()
        try store.save(
            description(lanes: [
                .init(kind: "microphone", captures: [.init(Fixtures.builtInMic), .init(Fixtures.usbMic)]),
                .init(kind: "systemAudio", captures: [.init(.systemAudio)]),
            ]),
            of: id
        )
        // The microphone switched devices after a second, with half a second between them.
        write([Fixtures.chunk(seconds: 1, hostTime: 100)], to: store.audioURL(of: id, lane: 0, capture: 0))
        write([Fixtures.chunk(seconds: 1, hostTime: 101.5)], to: store.audioURL(of: id, lane: 0, capture: 1))
        // System audio started a second later.
        write([Fixtures.chunk(seconds: 2, hostTime: 101)], to: store.audioURL(of: id, lane: 1, capture: 0))

        let recordings = store.recordings()
        #expect(
            recordings == [
                UnfinishedRecording(
                    id: id,
                    startedAt: Fixtures.startDate,
                    duration: 3,
                    sources: [Fixtures.builtInMic, Fixtures.usbMic, .systemAudio].map {
                        AudioInputDevice(id: $0.id, name: $0.name, kind: $0.kind)
                    },
                    isOnDisk: true
                )
            ]
        )

        let stored = try store.load(id)
        #expect(stored.description.language == "de")
        #expect(stored.description.recordingTrigger == .automatic)
        #expect(stored.description.isCall)
        #expect(stored.description.recordedMoments.map(\.text) == ["Budget"])
        #expect(stored.lanes.map(\.device.id) == [Fixtures.builtInMic.id, AudioInputDevice.systemAudioID])
        let microphone = stored.lanes[0].audio
        #expect(microphone.track.duration == 2.5)
        #expect(microphone.track.samples.count == 40_000)
        #expect(microphone.parts.map(\.device.id) == [Fixtures.builtInMic.id, Fixtures.usbMic.id])
        #expect(microphone.parts.map(\.start) == [0, 1.5])
        #expect(stored.lanes[1].audio.track.startHostTime == 101)
    }

    @Test func leavesOutCapturesWithoutAudio() throws {
        let store = Self.makeStore()
        defer { Self.remove(store) }
        let id = UUID()
        try store.save(
            description(lanes: [
                .init(kind: "microphone", captures: [.init(Fixtures.builtInMic), .init(Fixtures.usbMic)])
            ]),
            of: id
        )
        write([Fixtures.chunk(seconds: 1)], to: store.audioURL(of: id, lane: 0, capture: 0))

        #expect(store.recordings().map(\.duration) == [1])
        let stored = try store.load(id)
        #expect(stored.lanes.map(\.audio.track.duration) == [1])
        #expect(stored.lanes.map(\.audio.track.startHostTime) == [nil])
    }

    @Test func deletesFoldersWithoutADescription() throws {
        let store = Self.makeStore()
        defer { Self.remove(store) }
        let id = UUID()
        write([Fixtures.chunk(seconds: 1)], to: store.audioURL(of: id, lane: 0, capture: 0))
        // Not created by `audioURL`; the description creates the folder.
        #expect(store.recordings().isEmpty)

        try FileManager.default.createDirectory(
            at: store.audioURL(of: id, lane: 0, capture: 0).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        write([Fixtures.chunk(seconds: 1)], to: store.audioURL(of: id, lane: 0, capture: 0))
        #expect(store.recordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(of: id, lane: 0, capture: 0).path))
    }

    @Test func deletesARecording() throws {
        let store = Self.makeStore()
        defer { Self.remove(store) }
        let id = UUID()
        try store.save(description(lanes: []), of: id)
        #expect(store.recordings().map(\.id) == [id])

        store.delete(id)
        store.delete(id)

        #expect(store.recordings().isEmpty)
    }
}

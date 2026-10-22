@preconcurrency import AVFoundation
import MixdownCore
import os

/// Reads whatever audio and video files AVFoundation can (M4A, MP3, WAV, AIFF, CAF, FLAC, MP4,
/// MOV, …) into 16 kHz mono samples, for importing them as notes.
///
/// The file's audio tracks are mixed by `AVAssetReaderAudioMixOutput` in their own format, then
/// `AudioResampler` averages the channels and converts the rate, as for a capture. Asking the
/// reader for mono instead would let the converter drop every channel but the first, such as one
/// side of a call recorded in stereo.
public struct AudioFileDecoder: AudioFileDecoding {
    public init() {}

    public func decode(_ url: URL) async throws -> DecodedAudio {
        let name = url.lastPathComponent
        // Files from the open panel are readable without it; ones dropped or opened from Finder
        // may need it.
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw AudioImportError.unreadable(name, reason: error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw AudioImportError.noAudio(name) }

        let samples = try Self.read(tracks, of: asset, duration: duration, name: name)
        return DecodedAudio(samples: samples, recordedAt: await Self.recordingDate(of: asset, at: url))
    }

    /// Every sample of `tracks`, mixed and converted. Stops if the task is cancelled.
    private static func read(
        _ tracks: [AVAssetTrack],
        of asset: AVAsset,
        duration: CMTime,
        name: String
    ) throws -> [Float] {
        let unreadable = { (error: (any Error)?) in
            AudioImportError.unreadable(name, reason: error?.localizedDescription ?? "Its audio isn't supported.")
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw unreadable(error)
        }
        // `nil` settings: uncompressed, in the tracks' own rate and channels.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw unreadable(nil) }
        reader.add(output)
        guard reader.startReading() else { throw unreadable(reader.error) }
        defer { reader.cancelReading() }

        let resampler: AudioResampler
        do {
            resampler = try AudioResampler()
        } catch {
            throw unreadable(error)
        }
        var samples: [Float] = []
        if duration.isNumeric, duration.seconds > 0 {
            samples.reserveCapacity(Int(duration.seconds * AudioChunk.sampleRate) + Int(AudioChunk.sampleRate))
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = pcmBuffer(from: sampleBuffer) else { continue }
            if let chunk = resampler.process(buffer, hostTime: nil) {
                samples += chunk.samples
            }
        }
        if reader.status == .failed { throw unreadable(reader.error) }
        return samples
    }

    /// `sampleBuffer`'s audio as a PCM buffer in its own format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                frameCapacity: AVAudioFrameCount(frames)
            )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            audioLogger.error("Couldn't copy imported audio: \(status, privacy: .public)")
            return nil
        }
        return buffer
    }

    /// When the file was recorded, from its metadata (e.g. a Voice Memo's), or else when it was
    /// created.
    private static func recordingDate(of asset: AVURLAsset, at url: URL) async -> Date? {
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            return date
        }
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}

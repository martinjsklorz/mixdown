import Foundation
import Testing

@testable import MixdownSpeechSwift

struct ModelCacheTests {
    private let model = CachedModel(repositoryID: "example/Model-1B", requiredFiles: ["config.json"])

    private func temporaryBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(component: "ModelCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func write(_ names: [String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data("{}".utf8).write(to: directory.appending(component: name))
        }
    }

    private func contents(of base: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: base.path)
    }

    @Test func checkingAMissingModelCreatesNothing() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(ModelCache.existingDirectory(for: model.repositoryID, base: base) == nil)
        #expect(!model.isDownloaded(base: base))
        #expect(!SpeechSwiftEngine.isDownloaded(.qwen3ASRSmall, base: base))
        #expect(!SpeechSwiftEngine.isDownloaded(.nemotronStreaming, base: base))
        #expect(try contents(of: base).isEmpty)
    }

    @Test func existingDirectoryIsTheOneLoadingUses() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let created = try model.directory(base: base)

        #expect(ModelCache.existingDirectory(for: model.repositoryID, base: base)?.path == created.path)
    }

    @Test func existingDirectoryPrefersAPopulatedLegacyFolder() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appending(component: "example_Model-1B")
        try write(["model.safetensors"], in: legacy)

        #expect(ModelCache.existingDirectory(for: model.repositoryID, base: base)?.path == legacy.path)
    }

    @Test func looksCompleteNeedsWeightsAndTheRequiredFiles() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try model.directory(base: base)

        #expect(!model.isDownloaded(base: base))
        try write(["config.json"], in: directory)
        #expect(!model.isDownloaded(base: base))
        try write(["model.safetensors"], in: directory)
        #expect(model.isDownloaded(base: base))
    }

    @Test func looksCompleteWithoutWeightsChecksTheNamedFilesOnly() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = CachedModel(
            repositoryID: "example/Frontend",
            requiredFiles: ["weights.npz"],
            requiresWeights: false
        )
        let directory = try model.directory(base: base)

        #expect(!model.looksComplete(in: directory))
        try write(["weights.npz"], in: directory)
        #expect(model.looksComplete(in: directory))
    }

    @Test func offlineModelsAlsoNeedTheVoiceActivityDetector() throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let qwen = SpeechSwiftModel.qwen3ASRSmall.cachedModel
        try write(qwen.requiredFiles + ["model.safetensors"], in: qwen.directory(base: base))

        #expect(!SpeechSwiftEngine.isDownloaded(.qwen3ASRSmall, base: base))
        let detector = VoiceActivityDetector.cachedModel
        try write(detector.requiredFiles, in: detector.directory(base: base))
        #expect(SpeechSwiftEngine.isDownloaded(.qwen3ASRSmall, base: base))
    }
}

import Foundation
import MixdownCore
import Testing

struct DiskUsageTests {
    @Test func countsFilesInSubfoldersAndSkipsWhatIsExcluded() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "DiskUsageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory.appending(path: "models/org/name", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let weights = directory.appending(path: "models/org/name/model.safetensors")
        try Data(count: 10_000).write(to: weights)
        try Data("{}".utf8).write(to: directory.appending(path: "models/org/name/config.json"))

        let all = DiskUsage.of(directory)
        let weightsOnly = DiskUsage.of(directory) { $0.pathExtension == "safetensors" }

        #expect(all.fileCount == 2)
        #expect(all.bytes >= 10_000)
        #expect(weightsOnly.fileCount == 1)
        #expect(weightsOnly.bytes >= 10_000)
    }
}

import Foundation

/// How much disk space a set of files takes up.
public struct DiskUsage: Equatable, Sendable {
    /// How many files were counted.
    public var fileCount: Int
    /// The space they take up on disk, in bytes.
    public var bytes: Int64

    public init(fileCount: Int = 0, bytes: Int64 = 0) {
        self.fileCount = fileCount
        self.bytes = bytes
    }

    /// The regular files in `directory` and its subfolders that `includes` accepts. Symbolic links
    /// aren't followed. A folder that doesn't exist, or can't be read, counts as empty.
    ///
    /// Counts the space allocated on disk, falling back to the file's length where the file
    /// system doesn't say.
    public static func of(
        _ directory: URL,
        options: FileManager.DirectoryEnumerationOptions = [],
        including includes: (URL) -> Bool = { _ in true }
    ) -> DiskUsage {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { _, _ in true }
            )
        else { return DiskUsage() }
        var usage = DiskUsage()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                includes(url)
            else { continue }
            usage.fileCount += 1
            usage.bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return usage
    }
}

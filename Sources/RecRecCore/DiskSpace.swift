import Foundation

public enum DiskSpace {
    /// Refuse to start a recording below this much free space on the target volume.
    public static let minimumBytesToStart: Int64 = 500_000_000

    /// Free capacity for "important" usage on the volume containing `url` (the URL itself need not exist;
    /// the nearest existing ancestor is used).
    public static func freeBytes(at url: URL) throws -> Int64 {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public static func ensureFreeSpace(at url: URL, minimumBytes: Int64 = minimumBytesToStart) throws {
        let free = try freeBytes(at: url)
        if free < minimumBytes {
            throw RecRecError.insufficientDiskSpace(availableBytes: free, requiredBytes: minimumBytes)
        }
    }
}

import Foundation

public enum RecRecError: LocalizedError, Equatable {
    case insufficientDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    case writerSetupFailed(String)
    case writerFailed(String)
    case noVideoFrames
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(available, required):
            let formatter = ByteCountFormatter()
            return "Not enough free disk space: \(formatter.string(fromByteCount: available)) available, \(formatter.string(fromByteCount: required)) required."
        case let .writerSetupFailed(reason):
            return "Could not create the recording file: \(reason)"
        case let .writerFailed(reason):
            return "Recording failed while writing: \(reason)"
        case .noVideoFrames:
            return "No video frames were captured."
        case let .exportFailed(reason):
            return "Export failed: \(reason)"
        }
    }
}

import Foundation
import os

/// Appends human-readable diagnostics to ~/Library/Logs/RecRec/RecRec.log (and mirrors them to the unified
/// log). Console.app is not always available to whoever is debugging, so the file is the primary record.
public final class DiagnosticLog {
    public static let shared = DiagnosticLog()

    public let fileURL: URL
    private let queue = DispatchQueue(label: "com.barsmike.RecRec.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "com.barsmike.RecRec", category: "diagnostics")
    private let formatter: DateFormatter
    private let maxBytes: UInt64 = 2_000_000

    private init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RecRec", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        fileURL = logs.appendingPathComponent("RecRec.log")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    public func log(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        queue.async { [self] in
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value,
              size > maxBytes else { return }
        let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}

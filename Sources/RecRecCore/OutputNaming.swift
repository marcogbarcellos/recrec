import Foundation

/// File names like "Recording 2026-09-07 at 22.41.05.mp4" (24-hour clock, sorts chronologically).
public enum OutputNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    public static func baseName(date: Date) -> String {
        "Recording \(formatter.string(from: date))"
    }

    public static func fileName(date: Date, container: Container) -> String {
        "\(baseName(date: date)).\(container.fileExtension)"
    }

    /// A URL in `directory` that does not exist yet (" 2", " 3", … appended on collision).
    public static func uniqueURL(in directory: URL, container: Container, date: Date,
                                 fileManager: FileManager = .default) -> URL {
        uniqueURL(in: directory, baseName: baseName(date: date), pathExtension: container.fileExtension, fileManager: fileManager)
    }

    /// A non-existing .gif URL next to `videoURL` with the same base name.
    public static func gifURL(for videoURL: URL, fileManager: FileManager = .default) -> URL {
        uniqueURL(in: videoURL.deletingLastPathComponent(),
                  baseName: videoURL.deletingPathExtension().lastPathComponent,
                  pathExtension: "gif", fileManager: fileManager)
    }

    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String, fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(pathExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter).\(pathExtension)")
            counter += 1
        }
        return candidate
    }
}

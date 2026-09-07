import Foundation
import RecRecCore

func registerOutputNamingTests(_ r: TestRunner) {
    r.test("file name is sortable 24-hour local time") {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 7; c.hour = 22; c.minute = 41; c.second = 5
        let date = Calendar.current.date(from: c)!
        try expectEqual(OutputNaming.fileName(date: date, container: .mp4), "Recording 2026-09-07 at 22.41.05.mp4")
        try expectEqual(OutputNaming.fileName(date: date, container: .mov), "Recording 2026-09-07 at 22.41.05.mov")
    }

    r.test("unique URL adds a counter on collision, GIF URL sits next to the video") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recrec-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date()
        let first = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expectEqual(first.lastPathComponent, OutputNaming.fileName(date: date, container: .mp4))
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expect(second.lastPathComponent.hasSuffix(" 2.mp4"), "got \(second.lastPathComponent)")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expect(third.lastPathComponent.hasSuffix(" 3.mp4"), "got \(third.lastPathComponent)")
        let gif = OutputNaming.gifURL(for: first)
        try expectEqual(gif.pathExtension, "gif")
        try expectEqual(gif.deletingPathExtension().lastPathComponent, first.deletingPathExtension().lastPathComponent)
        try expectEqual(gif.deletingLastPathComponent().path, first.deletingLastPathComponent().path)
    }

    r.test("disk space is positive, works for a not-yet-created folder, and the guard throws for absurd minimums") {
        let tmp = FileManager.default.temporaryDirectory
        let free = try DiskSpace.freeBytes(at: tmp)
        try expect(free > 0)
        let missing = tmp.appendingPathComponent("does-not-exist-\(UUID().uuidString)/nested")
        let missingFree = try DiskSpace.freeBytes(at: missing)
        try expect(missingFree > 0, "nearest existing ancestor is used")
        try DiskSpace.ensureFreeSpace(at: tmp, minimumBytes: 1)
        try await expectThrows { try DiskSpace.ensureFreeSpace(at: tmp, minimumBytes: Int64.max) }
    }
}

import Foundation
import AVFoundation
import ImageIO
import RecRecCore

func registerGIFExporterTests(_ r: TestRunner) {
    r.test("exports a GIF at 10 fps scaled to the max width") {
        let video = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(video) }
        let writer = try RecordingWriter(configuration: WriterConfiguration(
            outputURL: video, container: .mp4,
            videoSettings: EncoderConfig.videoSettings(codec: .h264, tier: .balanced, scale: .standard, width: 1600, height: 900, frameRate: 30),
            audioTracks: [], clock: CMClockGetHostTimeClock(), frameRate: 30, automaticHeartbeat: false))
        for i in 0..<60 {
            writer.appendVideo(SyntheticMedia.pixelBuffer(width: 1600, height: 900, frame: i),
                               presentationTime: CMTime(value: CMTimeValue(i), timescale: 30), status: .complete)
        }
        _ = try await writer.finish(at: CMTime(value: 60, timescale: 30))

        let gif = SyntheticMedia.tempURL("gif")
        defer { SyntheticMedia.cleanup(gif) }
        var lastProgress = 0.0
        let exportStart = Date()
        var firstFrameAt: Date?
        var lastFrameAt: Date?
        let frames = try await GIFExporter.export(video: video, to: gif, options: GIFExportOptions(framesPerSecond: 10, maxWidth: 800)) {
            lastProgress = $0
            if firstFrameAt == nil { firstFrameAt = Date() }
            lastFrameAt = Date()
        }
        if ProcessInfo.processInfo.environment["GIF_TIMING"] != nil {
            print("      first frame after \(firstFrameAt!.timeIntervalSince(exportStart))s, last frame after \(lastFrameAt!.timeIntervalSince(exportStart))s, total \(Date().timeIntervalSince(exportStart))s")
        }
        try expectEqual(frames, 20)
        try expectNear(lastProgress, 1.0, tolerance: 0.001)
        let source = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        try expectEqual(CGImageSourceGetCount(source), 20)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        try expectEqual(properties[kCGImagePropertyPixelWidth] as? Int, 800)
        try expectEqual(properties[kCGImagePropertyPixelHeight] as? Int, 450)
        let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        try expectNear(gifProperties?[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.1, tolerance: 0.001)
    }

    r.test("export of a missing file fails and leaves no output") {
        let gif = SyntheticMedia.tempURL("gif")
        try await expectThrows {
            try await GIFExporter.export(video: SyntheticMedia.tempURL("mp4"), to: gif)
        }
        try expectEqual(FileManager.default.fileExists(atPath: gif.path), false)
    }
}

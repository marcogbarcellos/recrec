import Foundation
import AVFoundation
import RecRecCore

/// Writers "abandoned" mid-recording are kept alive so AVAssetWriter's deallocation cannot tidy up the file;
/// the test then reads the unfinished file the way a user would after a crash.
private var abandonedWriters: [RecordingWriter] = []

func registerRecordingWriterTests(_ r: TestRunner) {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    let frame = 1.0 / 30.0

    func config(_ url: URL, codec: VideoCodec = .hevc, container: Container = .mp4, audio: [AudioTrackKind] = [],
                fragment: Double = EncoderConfig.fragmentIntervalSeconds) -> WriterConfiguration {
        WriterConfiguration(
            outputURL: url, container: container,
            videoSettings: EncoderConfig.videoSettings(codec: codec, tier: .balanced, scale: .standard, width: 640, height: 360, frameRate: 30),
            audioTracks: audio.map { AudioTrackSpec(kind: $0, settings: EncoderConfig.audioSettings(kind: $0)) },
            clock: CMClockGetHostTimeClock(), frameRate: 30, fragmentInterval: fragment, automaticHeartbeat: false)
    }

    func feed(_ w: RecordingWriter, frames: Range<Int>, status: FrameStatus = .complete, offset: Double = 0) {
        for i in frames {
            w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i),
                          presentationTime: t(offset + Double(i) / 30), status: status)
        }
    }

    r.test("writer produces a playable HEVC mp4 with the session duration and a final frame") {
        let url = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url))
        feed(w, frames: 0..<90)
        let result = try await w.finish(at: t(3))
        let info = try await SyntheticMedia.inspect(url)
        try expectNear(info.duration, 3.0 + frame, tolerance: 0.02)
        try expectEqual(info.videoFrames, 91, "90 frames + final frame at 3 s")
        try expectEqual(result.videoFrames, 91)
        try expectEqual(info.codec, "hvc1")
        try expectEqual(info.width, 640)
        try expectEqual(info.height, 360)
        try expect(result.fileSize > 1000, "size \(result.fileSize)")
        try expectEqual(result.url, url)
        try expectNear(result.duration, 3.0 + frame, tolerance: 0.001)
    }

    r.test("idle frames are skipped, heartbeat re-appends, idle tail keeps the duration") {
        let url = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url))
        feed(w, frames: 0..<30)
        feed(w, frames: 30..<150, status: .idle)
        w.heartbeat(now: t(1.5))   // not due: last frame at 0.967 s
        w.heartbeat(now: t(3.0))   // due → re-append at 3.0 s
        let result = try await w.finish(at: t(5))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.videoFrames, 32, "30 complete + 1 heartbeat + 1 final")
        try expectNear(info.duration, 5.0 + frame, tolerance: 0.02)
        try expectNear(result.duration, 5.0 + frame, tolerance: 0.001)
    }

    r.test("session starts at the first complete frame; earlier idle frames are ignored") {
        let url = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url))
        w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: 0), presentationTime: t(10), status: .idle)
        feed(w, frames: 0..<30, offset: 11)
        let result = try await w.finish(at: t(12))
        try expectNear(result.duration, 1.0 + frame, tolerance: 0.001)
        let info = try await SyntheticMedia.inspect(url)
        try expectNear(info.duration, 1.0 + frame, tolerance: 0.02)
        try expectEqual(info.videoFrames, 31)
    }

    r.test("finish before the last frame ends still yields a monotonic final frame") {
        let url = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url))
        feed(w, frames: 0..<30)
        let result = try await w.finish(at: t(0.5))   // earlier than the last appended frame (0.967 s)
        try expectNear(result.duration, 1.0 + frame, tolerance: 0.001)
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.videoFrames, 31)
    }

    r.test("h264 mov output with fragments is readable, and moof atoms exist") {
        let url = SyntheticMedia.tempURL("mov")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url, codec: .h264, container: .mov, fragment: 1))
        feed(w, frames: 0..<120)
        _ = try await w.finish(at: t(4))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.codec, "avc1")
        try expectNear(info.duration, 4.0 + frame, tolerance: 0.02)
        let moofs = try SyntheticMedia.countAtoms(url, "moof")
        try expect(moofs >= 2, "expected movie fragments, found \(moofs)")
    }

    r.test("a file left unfinished is still readable thanks to fragments") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url, fragment: 1))
        feed(w, frames: 0..<180)
        await w.abandonForTesting()
        abandonedWriters.append(w)
        let info = try await SyntheticMedia.inspect(url)
        SyntheticMedia.cleanup(url)
        try expect(info.duration >= 3.0, "recovered \(info.duration)s of 6 s")
    }

    r.test("microphone audio is written as a track, including a buffer that starts before the session") {
        let url = SyntheticMedia.tempURL("mp4")
        defer { SyntheticMedia.cleanup(url) }
        let w = try RecordingWriter(configuration: config(url, audio: [.microphone]))
        w.appendAudio(SyntheticMedia.audioSampleBuffer(startTime: t(-0.1), frames: 4800), kind: .microphone)  // before session: dropped
        for i in 0..<60 {
            w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete)
            if i % 3 == 0 {
                w.appendAudio(SyntheticMedia.audioSampleBuffer(startTime: t(Double(i) / 30), frames: 4800), kind: .microphone)
            }
        }
        let result = try await w.finish(at: t(2))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.hasAudio, true)
        try expectNear(info.duration, 2.0 + frame, tolerance: 0.1)
        try expect(result.fileSize > 0)
    }

    r.test("finishing with no frames throws noVideoFrames and removes the file") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url))
        try await expectThrows { _ = try await w.finish(at: t(1)) }
        try expectEqual(FileManager.default.fileExists(atPath: url.path), false)
    }
}

import Foundation
import AVFoundation
import CoreMedia
import os

public struct AudioTrackSpec {
    public var kind: AudioTrackKind
    public var settings: [String: Any]

    public init(kind: AudioTrackKind, settings: [String: Any]) {
        self.kind = kind
        self.settings = settings
    }
}

public struct WriterConfiguration {
    public var outputURL: URL
    public var container: Container
    public var videoSettings: [String: Any]
    public var audioTracks: [AudioTrackSpec]
    /// Clock the video timestamps live on (ScreenCaptureKit's synchronization clock); used for heartbeats.
    public var clock: CMClock
    /// Nominal capture frame rate; every appended frame carries a duration of one frame.
    public var frameRate: Int
    public var heartbeatInterval: Double
    public var fragmentInterval: Double
    /// When false the internal heartbeat timer is not started (tests drive `heartbeat(now:)` themselves).
    public var automaticHeartbeat: Bool

    public init(outputURL: URL, container: Container, videoSettings: [String: Any], audioTracks: [AudioTrackSpec],
                clock: CMClock, frameRate: Int = 30,
                heartbeatInterval: Double = EncoderConfig.heartbeatIntervalSeconds,
                fragmentInterval: Double = EncoderConfig.fragmentIntervalSeconds,
                automaticHeartbeat: Bool = true) {
        self.outputURL = outputURL
        self.container = container
        self.videoSettings = videoSettings
        self.audioTracks = audioTracks
        self.clock = clock
        self.frameRate = frameRate
        self.heartbeatInterval = heartbeatInterval
        self.fragmentInterval = fragmentInterval
        self.automaticHeartbeat = automaticHeartbeat
    }

    var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate))) }
}

public struct AudioTrackStats: Equatable {
    public var accepted = 0
    public var droppedBeforeSession = 0
    public var droppedFormatChanged = 0
    public var droppedNotReady = 0
    public var appendFailed = 0
    public var firstPresentationTime: Double?
    public var lastPresentationTime: Double?

    public var summary: String {
        var parts = ["accepted \(accepted)"]
        if droppedBeforeSession > 0 { parts.append("before-session \(droppedBeforeSession)") }
        if droppedFormatChanged > 0 { parts.append("format-changed \(droppedFormatChanged)") }
        if droppedNotReady > 0 { parts.append("not-ready \(droppedNotReady)") }
        if appendFailed > 0 { parts.append("append-failed \(appendFailed)") }
        if let first = firstPresentationTime, let last = lastPresentationTime {
            parts.append(String(format: "span %.3f→%.3f s", first, last))
        }
        return parts.joined(separator: ", ")
    }
}

public struct RecordingResult: Equatable {
    public var url: URL
    /// Media duration in seconds (what every player reports).
    public var duration: Double
    public var fileSize: Int64
    public var videoFrames: Int
    public var audioStats: [AudioTrackKind: AudioTrackStats] = [:]
}

/// Wraps AVAssetWriter for a live capture: video frames with explicit one-frame durations, idle-frame
/// skipping with heartbeats, optional AAC audio tracks, and movie fragments for crash safety.
/// Thread-safe: every call is serialized on an internal queue.
public final class RecordingWriter {
    public let configuration: WriterConfiguration
    /// Called (on the writer queue) the first time the underlying writer fails.
    public var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.barsmike.RecRec.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
    private var audioFormats: [AudioTrackKind: CMFormatDescription] = [:]
    private var audioStats: [AudioTrackKind: AudioTrackStats] = [:]
    private var gate: FrameGate
    private var sessionStart: CMTime = .invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private var videoFormat: CMVideoFormatDescription?
    private var videoFrames = 0
    private var droppedFrames = 0
    private var reportedError = false
    private var finished = false
    private var timer: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "writer")
    private let diagnostics = DiagnosticLog.shared

    public init(configuration: WriterConfiguration) throws {
        self.configuration = configuration
        let fileType: AVFileType = configuration.container == .mov ? .mov : .mp4
        do {
            writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: fileType)
        } catch {
            throw RecRecError.writerSetupFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = false
        if configuration.fragmentInterval > 0 {
            writer.movieFragmentInterval = CMTime(seconds: configuration.fragmentInterval, preferredTimescale: 600)
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: configuration.videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecRecError.writerSetupFailed("video settings rejected") }
        writer.add(videoInput)
        for track in configuration.audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: track.settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecRecError.writerSetupFailed("audio settings rejected") }
            writer.add(input)
            audioInputs[track.kind] = input
        }
        gate = FrameGate(heartbeatInterval: CMTime(seconds: configuration.heartbeatInterval, preferredTimescale: 600))
        guard writer.startWriting() else {
            throw RecRecError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        if configuration.automaticHeartbeat {
            startHeartbeatTimer()
        }
    }

    // MARK: - Appending

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, status: FrameStatus) {
        queue.async { [self] in
            guard !finished, gate.decide(status: status, presentationTime: presentationTime) else { return }
            if !sessionStart.isValid {
                sessionStart = presentationTime
                writer.startSession(atSourceTime: presentationTime)
            }
            append(pixelBuffer, at: presentationTime)
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind) {
        queue.async { [self] in
            guard !finished, let input = audioInputs[kind] else { return }
            var stats = audioStats[kind] ?? AudioTrackStats()
            defer { audioStats[kind] = stats }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sampleBuffer))
            guard sessionStart.isValid, CMTimeCompare(end, sessionStart) > 0 else { stats.droppedBeforeSession += 1; return }
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            if let locked = audioFormats[kind] {
                // The AAC converter is configured from the first buffer; a different format would corrupt the track.
                guard CMFormatDescriptionEqual(locked, otherFormatDescription: format) else {
                    if stats.droppedFormatChanged == 0 {
                        diagnostics.log("writer", "\(kind.rawValue) audio format changed after \(stats.accepted) buffers; dropping the rest")
                    }
                    stats.droppedFormatChanged += 1
                    return
                }
            } else {
                audioFormats[kind] = format
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    diagnostics.log("writer", String(format: "%@ audio starts at %.3f s (session %.3f): rate=%d ch=%d bits=%d", kind.rawValue, pts.seconds, sessionStart.seconds, Int(asbd.mSampleRate), asbd.mChannelsPerFrame, asbd.mBitsPerChannel))
                }
            }
            guard writer.status == .writing else { reportFailure(); return }
            guard waitUntilReady(input) else { stats.droppedNotReady += 1; return }
            if input.append(sampleBuffer) {
                stats.accepted += 1
                if stats.firstPresentationTime == nil { stats.firstPresentationTime = pts.seconds }
                stats.lastPresentationTime = end.seconds
            } else {
                stats.appendFailed += 1
                if stats.appendFailed == 1 {
                    diagnostics.log("writer", "\(kind.rawValue) audio append failed: \(writer.error?.localizedDescription ?? "no error"), status \(writer.status.rawValue)")
                }
                reportFailure()
            }
        }
    }

    /// Re-appends the last frame when nothing was written for the heartbeat interval.
    public func heartbeat(now: CMTime) {
        queue.async { [self] in
            heartbeatOnQueue(now: now)
        }
    }

    // MARK: - Finishing

    public func finish(at endTime: CMTime) async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingResult, Error>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                guard !finished else {
                    continuation.resume(throwing: RecRecError.writerFailed("already finished"))
                    return
                }
                finished = true
                guard sessionStart.isValid, lastPixelBuffer != nil else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: configuration.outputURL)
                    continuation.resume(throwing: RecRecError.noVideoFrames)
                    return
                }
                let frameDuration = configuration.frameDuration
                // A real final frame with an explicit duration: AVAssetWriter would otherwise give the last sample
                // the previous inter-frame gap (a frozen tail), and endSession alone only extends the edit list.
                let earliest = CMTimeAdd(gate.lastAppended, frameDuration)
                let finalTime = CMTimeCompare(endTime, earliest) > 0 ? endTime : earliest
                if writer.status == .writing, let last = lastPixelBuffer {
                    var spins = 0
                    while !videoInput.isReadyForMoreMediaData && writer.status == .writing && spins < 200 {
                        usleep(5_000)   // up to 1 s: the final frame matters more than latency
                        spins += 1
                    }
                    gate.noteAppended(at: finalTime)
                    append(last, at: finalTime)
                }
                if writer.status == .failed {
                    continuation.resume(throwing: RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    return
                }
                let sessionEnd = CMTimeAdd(finalTime, frameDuration)
                videoInput.markAsFinished()
                audioInputs.values.forEach { $0.markAsFinished() }
                writer.endSession(atSourceTime: sessionEnd)
                let duration = CMTimeGetSeconds(CMTimeSubtract(sessionEnd, sessionStart))
                let frames = videoFrames
                let dropped = droppedFrames
                let stats = audioStats
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.outputURL.path)
                        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                        let audioSummary = stats.map { "\($0.key.rawValue): \($0.value.summary)" }.sorted().joined(separator: "; ")
                        diagnostics.log("writer", String(format: "finished %@: %.2f s, %d video frames (%d dropped), %lld bytes%@", configuration.outputURL.lastPathComponent, duration, frames, dropped, size, audioSummary.isEmpty ? "" : " | audio " + audioSummary))
                        continuation.resume(returning: RecordingResult(url: configuration.outputURL, duration: duration, fileSize: size, videoFrames: frames, audioStats: stats))
                    } else {
                        continuation.resume(throwing: RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    }
                }
            }
        }
    }

    /// Abandons the recording and deletes the file; used when starting fails after the file was created.
    public func cancel() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            guard !finished else { return }
            finished = true
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: configuration.outputURL)
        }
    }

    /// Test hook: stops the heartbeat and leaves the file unfinished, simulating a crash.
    public func abandonForTesting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                finished = true
                continuation.resume()
            }
        }
    }

    // MARK: - Private (writer queue)

    private func heartbeatOnQueue(now: CMTime) {
        guard !finished, writer.status == .writing, gate.heartbeatDue(now: now), let last = lastPixelBuffer else { return }
        gate.noteAppended(at: now)
        append(last, at: now)
    }

    /// Waits briefly (two frame durations) for the encoder to accept more data. Real-time inputs keep only a
    /// tiny queue, so a momentary stall would otherwise drop frames; anything longer is dropped on purpose.
    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        let budget = max(0.01, CMTimeGetSeconds(configuration.frameDuration) * 2)
        let deadline = Date().addingTimeInterval(budget)
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || Date() >= deadline { return input.isReadyForMoreMediaData }
            usleep(500)
        }
        return true
    }

    private func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { reportFailure(); return }
        guard waitUntilReady(videoInput) else {
            droppedFrames += 1
            if droppedFrames == 1 { diagnostics.log("writer", "video input not ready; dropping a frame at \(time.seconds)") }
            return
        }
        guard let sampleBuffer = makeSampleBuffer(pixelBuffer, at: time) else { droppedFrames += 1; return }
        if videoInput.append(sampleBuffer) {
            lastPixelBuffer = pixelBuffer
            videoFrames += 1
        } else {
            reportFailure()
        }
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        if let cached = videoFormat, !CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
            videoFormat = nil
        }
        if videoFormat == nil {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            videoFormat = description
        }
        guard let format = videoFormat else { return nil }
        var timing = CMSampleTimingInfo(duration: configuration.frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                              formatDescription: format, sampleTiming: &timing,
                                                              sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }

    private func reportFailure() {
        guard !reportedError, writer.status == .failed else { return }
        reportedError = true
        let error = RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        log.error("writer failed: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    private func startHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = max(0.25, configuration.heartbeatInterval / 2)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.heartbeatOnQueue(now: CMClockGetTime(self.configuration.clock))
        }
        timer.resume()
        self.timer = timer
    }
}

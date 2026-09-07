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

public struct RecordingResult: Equatable {
    public var url: URL
    /// Media duration in seconds (what every player reports).
    public var duration: Double
    public var fileSize: Int64
    public var videoFrames: Int
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
            guard !finished, sessionStart.isValid, let input = audioInputs[kind] else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sampleBuffer))
            guard CMTimeCompare(end, sessionStart) > 0 else { return }
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            if let locked = audioFormats[kind] {
                // The AAC converter is configured from the first buffer; a different format would corrupt the track.
                guard CMFormatDescriptionEqual(locked, otherFormatDescription: format) else {
                    log.warning("dropping \(kind.rawValue, privacy: .public) audio buffer with a changed format")
                    return
                }
            } else {
                audioFormats[kind] = format
            }
            guard writer.status == .writing else { reportFailure(); return }
            guard input.isReadyForMoreMediaData else { return }
            if !input.append(sampleBuffer) { reportFailure() }
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
                        usleep(5_000)
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
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.outputURL.path)
                        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                        log.info("finished \(self.configuration.outputURL.lastPathComponent, privacy: .public): \(frames) frames, \(dropped) dropped, \(size) bytes")
                        continuation.resume(returning: RecordingResult(url: configuration.outputURL, duration: duration, fileSize: size, videoFrames: frames))
                    } else {
                        continuation.resume(throwing: RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    }
                }
            }
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

    private func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { reportFailure(); return }
        guard videoInput.isReadyForMoreMediaData else { droppedFrames += 1; return }
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

import AppKit
import AVFoundation
import ScreenCaptureKit
import os
import RecRecCore

enum RecorderError: LocalizedError {
    case screenRecordingDenied
    case microphoneDenied
    case noDisplay
    case noMicrophone
    case noCamera
    case streamStopped(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied: return "Screen Recording permission was not granted."
        case .microphoneDenied: return "Microphone permission was not granted."
        case .noDisplay: return "No display is available to record."
        case .noMicrophone: return "No microphone was found."
        case .noCamera: return "No camera was found."
        case .streamStopped(let reason): return "The capture stopped: \(reason)"
        }
    }
}

/// Drives one ScreenCaptureKit stream into a RecordingWriter. State changes happen on the main actor;
/// capture callbacks arrive through StreamOutputRelay on a private queue.
@MainActor
final class ScreenRecorder: Recorder {
    private(set) var state: RecorderState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((RecorderState) -> Void)?
    var onFinished: ((Result<RecordingResult, Error>) -> Void)?

    private let relay = StreamOutputRelay()
    private let captureQueue = DispatchQueue(label: "com.barsmike.RecRec.capture", qos: .userInitiated)
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "recorder")
    private let diagnostics = DiagnosticLog.shared
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var microphone: MicrophoneCapture?
    private var activity: NSObjectProtocol?
    private var stopError: Error?
    private var sleepObserver: NSObjectProtocol?

    init() {
        relay.onStop = { error in
            Task { @MainActor [weak self] in await self?.streamDidStop(error) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in await self?.systemWillSleep() }
        }
    }

    // MARK: - Recorder

    func start(settings: RecordingSettings) async throws {
        guard state == .idle else { return }
        state = .preparing
        var pendingWriter: RecordingWriter?
        do {
            try DiskSpace.ensureFreeSpace(at: settings.saveDirectory)
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()   // shows the system prompt on first use
                throw RecorderError.screenRecordingDenied
            }
            if settings.microphoneEnabled {
                guard await MicrophoneCapture.requestAccess() else { throw RecorderError.microphoneDenied }
            }

            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                log.error("shareable content failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.screenRecordingDenied
            }
            guard let display = DisplaySelection.choose(from: content.displays, pinned: settings.pinnedDisplayID) else {
                throw RecorderError.noDisplay
            }
            // Hide only our status-bar item (the "● 00:12" timer); other RecRec windows, such as the camera
            // bubble, are meant to be part of the recording.
            let statusWindowIDs = WindowIDs.valid(NSApp.windows
                .filter { String(describing: type(of: $0)).contains("StatusBar") }
                .map(\.windowNumber))
            let excludedWindows = content.windows.filter { statusWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            diagnostics.log("recorder", "excluding \(excludedWindows.count) status-bar window(s) from the capture")
            let geometry = EncoderConfig.captureGeometry(
                pointSize: CGSize(width: display.width, height: display.height),
                pixelSize: DisplaySelection.pixelSize(of: display.displayID),
                scale: settings.resolution,
                codec: settings.codec)
            let configuration = Self.streamConfiguration(settings: settings, geometry: geometry)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
            let clock = stream.synchronizationClock ?? CMClockGetHostTimeClock()
            diagnostics.log("recorder", "stream clock \(stream.synchronizationClock == nil ? "nil → host clock" : (stream.synchronizationClock === CMClockGetHostTimeClock() ? "is the host clock" : "is a separate clock")); host now \(String(format: "%.3f", CMClockGetTime(CMClockGetHostTimeClock()).seconds)), stream now \(String(format: "%.3f", CMClockGetTime(clock).seconds))")

            var audioTracks: [AudioTrackSpec] = []
            if settings.systemAudioEnabled {
                audioTracks.append(AudioTrackSpec(kind: .system, settings: EncoderConfig.audioSettings(kind: .system)))
            }
            if settings.microphoneEnabled {
                audioTracks.append(AudioTrackSpec(kind: .microphone, settings: EncoderConfig.audioSettings(kind: .microphone)))
            }
            try FileManager.default.createDirectory(at: settings.saveDirectory, withIntermediateDirectories: true)
            let url = OutputNaming.uniqueURL(in: settings.saveDirectory, container: settings.container, date: Date())
            let writer = try RecordingWriter(configuration: WriterConfiguration(
                outputURL: url,
                container: settings.container,
                videoSettings: EncoderConfig.videoSettings(codec: settings.codec, tier: settings.quality, scale: settings.resolution,
                                                           width: geometry.width, height: geometry.height, frameRate: settings.frameRate),
                audioTracks: audioTracks,
                clock: clock,
                frameRate: settings.frameRate))
            pendingWriter = writer
            writer.onError = { error in
                Task { @MainActor [weak self] in await self?.writerDidFail(error) }
            }

            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: captureQueue)
            if settings.systemAudioEnabled {
                try stream.addStreamOutput(relay, type: .audio, sampleHandlerQueue: captureQueue)
            }
            var microphone: MicrophoneCapture?
            if settings.microphoneEnabled {
                let capture = try MicrophoneCapture(streamClock: clock)
                capture.onSampleBuffer = { [weak writer] buffer in writer?.appendAudio(buffer, kind: .microphone) }
                microphone = capture
            }

            relay.attach(writer)
            try await stream.startCapture()
            microphone?.start()

            self.stream = stream
            self.writer = writer
            self.microphone = microphone
            self.stopError = nil
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Screen recording")
            state = .recording(since: Date())
            diagnostics.log("recorder", "started \(url.lastPathComponent): \(geometry.width)x\(geometry.height) \(settings.codec.rawValue) \(settings.quality.rawValue) \(settings.frameRate) fps mic=\(settings.microphoneEnabled) systemAudio=\(settings.systemAudioEnabled) display=\(display.displayID)")
        } catch {
            relay.detach()
            pendingWriter?.cancel()   // no half-written file for a recording that never started
            diagnostics.log("recorder", "start failed: \(error.localizedDescription)")
            state = .idle
            throw error
        }
    }

    func stop() async {
        guard case .recording = state, let writer, let stream else { return }
        state = .stopping
        do {
            try await stream.stopCapture()
        } catch {
            log.error("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        microphone?.stop()
        relay.detach()
        let endTime = CMClockGetTime(writer.configuration.clock)
        var outcome: Result<RecordingResult, Error>
        do {
            outcome = .success(try await writer.finish(at: endTime))
        } catch {
            diagnostics.log("recorder", "finish failed: \(error.localizedDescription)")
            outcome = .failure(error)
        }
        if case .success = outcome, let stopError {
            outcome = .failure(stopError)
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        self.stream = nil
        self.writer = nil
        self.microphone = nil
        state = .idle
        onFinished?(outcome)
    }

    // MARK: - Events

    private func streamDidStop(_ error: Error?) async {
        guard case .recording = state else { return }
        if let error {
            let nsError = error as NSError
            // -3817 = SCStreamErrorUserStopped (the user pressed Stop in the system's recording indicator);
            // the constant is not in the macOS 14.2 SDK headers.
            if nsError.domain == SCStreamErrorDomain && nsError.code == -3817 {
                diagnostics.log("recorder", "stream stopped by the user from the system indicator")
            } else {
                diagnostics.log("recorder", "stream stopped with error: \(error.localizedDescription)")
                stopError = RecorderError.streamStopped(error.localizedDescription)
            }
        }
        await stop()
    }

    private func writerDidFail(_ error: Error) async {
        guard case .recording = state else { return }
        stopError = error
        await stop()
    }

    private func systemWillSleep() async {
        guard case .recording = state else { return }
        log.info("system going to sleep; finalizing the recording")
        await stop()
    }

    // MARK: - Configuration

    static func streamConfiguration(settings: RecordingSettings, geometry: CaptureGeometry) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.width
        configuration.height = geometry.height
        configuration.sourceRect = geometry.sourceRect
        configuration.scalesToFit = false
        configuration.captureResolution = geometry.usesNominalResolution ? .nominal : .best
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.frameRate)))
        configuration.queueDepth = 6
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = settings.systemAudioEnabled
        configuration.sampleRate = Int(EncoderConfig.audioSampleRate)
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.streamName = "RecRec"
        return configuration
    }
}

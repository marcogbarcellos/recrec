import AVFoundation
import CoreMedia
import RecRecCore

/// Captures the default microphone through AVCaptureSession and shifts each buffer onto the
/// ScreenCaptureKit stream clock so audio lines up with video.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    /// Delivers sample buffers; must never block on the session queue.
    private let queue = DispatchQueue(label: "com.barsmike.RecRec.microphone", qos: .userInitiated)
    /// startRunning/stopRunning block, so they run here rather than on the main actor or the delegate queue.
    private let sessionQueue = DispatchQueue(label: "com.barsmike.RecRec.microphone.session", qos: .userInitiated)
    private let streamClock: CMClock
    private let diagnostics = DiagnosticLog.shared
    private var observers: [NSObjectProtocol] = []
    private var delivered = 0
    private var lastFormat = ""
    private var lastPresentationTime = CMTime.invalid

    init(streamClock: CMClock) throws {
        self.streamClock = streamClock
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.noMicrophone
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        let active = device.activeFormat.formatDescription.audioStreamBasicDescription
        diagnostics.log("mic", "device \"\(device.localizedName)\" active format rate=\(active?.mSampleRate ?? 0) ch=\(active?.mChannelsPerFrame ?? 0) bits=\(active?.mBitsPerChannel ?? 0)")
        observeSessionEvents()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    func stop() {
        queue.sync { self.onSampleBuffer = nil }
        let session = self.session
        let delivered = self.delivered
        sessionQueue.async { session.stopRunning() }
        diagnostics.log("mic", "stopped after \(delivered) buffers")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = onSampleBuffer else { return }
        delivered += 1
        logBufferIfInteresting(sampleBuffer)

        guard let sessionClock = session.synchronizationClock, sessionClock !== streamClock else {
            handler(sampleBuffer)
            return
        }
        let converted = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: sessionClock, to: streamClock)
        if let shifted = SampleBufferTiming.shifted(sampleBuffer, toStartAt: converted) {
            handler(shifted)
        } else {
            diagnostics.log("mic", "could not re-time buffer #\(delivered); passing it through")
            handler(sampleBuffer)
        }
    }

    // MARK: - Diagnostics

    private func logBufferIfInteresting(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var format = "no format"
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            format = "rate=\(Int(asbd.mSampleRate)) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)"
        }
        let gap = lastPresentationTime.isValid ? CMTimeSubtract(pts, lastPresentationTime).seconds : 0
        let formatChanged = delivered > 1 && format != lastFormat
        if delivered <= 3 || formatChanged || gap > 0.25 || delivered % 500 == 0 {
            let clockNote: String
            if let sessionClock = session.synchronizationClock {
                let converted = CMSyncConvertTime(pts, from: sessionClock, to: streamClock)
                clockNote = sessionClock === streamClock ? "same clock" : String(format: "converted=%.3f (offset %+.4f s)", converted.seconds, converted.seconds - pts.seconds)
            } else {
                clockNote = "session clock nil"
            }
            diagnostics.log("mic", String(format: "buffer #%d %@ pts=%.3f gap=%.3f frames=%d %@%@", delivered, format, pts.seconds, gap,
                                          CMSampleBufferGetNumSamples(sampleBuffer), clockNote, formatChanged ? " FORMAT CHANGED" : ""))
        }
        lastFormat = format
        lastPresentationTime = pts
    }

    private func observeSessionEvents() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .AVCaptureSessionRuntimeError, .AVCaptureSessionWasInterrupted, .AVCaptureSessionInterruptionEnded,
            .AVCaptureSessionDidStartRunning, .AVCaptureSessionDidStopRunning,
            .AVCaptureDeviceWasDisconnected, .AVCaptureDeviceWasConnected,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self else { return }
                if let object = notification.object as? AVCaptureSession, object !== self.session { return }
                let error = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error).map { " error=\($0.localizedDescription)" } ?? ""
                let device = (notification.object as? AVCaptureDevice).map { " device=\($0.localizedName)" } ?? ""
                self.diagnostics.log("mic", "\(name.rawValue)\(error)\(device)")
            })
        }
    }
}

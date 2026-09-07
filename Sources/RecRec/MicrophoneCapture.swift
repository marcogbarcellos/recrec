import AVFoundation
import CoreMedia
import os

/// Captures the default microphone through AVCaptureSession and re-times each buffer onto the
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
    private let queue = DispatchQueue(label: "com.barsmike.RecRec.microphone", qos: .userInitiated)
    private let streamClock: CMClock
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "microphone")

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
        log.info("microphone: \(device.localizedName, privacy: .public)")
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.sync {
            self.onSampleBuffer = nil
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = onSampleBuffer else { return }
        guard let sessionClock = session.synchronizationClock, sessionClock !== streamClock else {
            handler(sampleBuffer)
            return
        }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: sessionClock, to: streamClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                            sampleBufferOut: &retimed)
        if status == noErr, let retimed {
            handler(retimed)
        } else {
            handler(sampleBuffer)
        }
    }
}

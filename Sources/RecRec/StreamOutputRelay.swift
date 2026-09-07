import Foundation
import ScreenCaptureKit
import RecRecCore

/// Receives SCStream callbacks on the capture queue and forwards them to the writer. It is deliberately
/// not main-actor isolated; the writer reference sits behind a lock so ScreenRecorder can swap it safely.
final class StreamOutputRelay: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    var onStop: ((Error?) -> Void)?

    func attach(_ writer: RecordingWriter) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        writer = nil
    }

    private var currentWriter: RecordingWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer = currentWriter, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            writer.appendVideo(pixelBuffer,
                               presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                               status: Self.frameStatus(of: sampleBuffer))
        case .audio:
            writer.appendAudio(sampleBuffer, kind: .system)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> FrameStatus {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return .other }
        switch status {
        case .complete: return .complete
        case .idle: return .idle
        default: return .other
        }
    }
}

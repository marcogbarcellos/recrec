import CoreMedia

public enum FrameStatus: Equatable {
    /// A new frame with changed content.
    case complete
    /// The screen did not change; ScreenCaptureKit delivered no new surface.
    case idle
    /// Blank, suspended, started/stopped markers, or a buffer without an image.
    case other
}

/// Decides which captured frames are written. Only complete frames with increasing timestamps are
/// appended; idle frames (unchanged screen) are skipped, and a heartbeat re-appends the last frame
/// when nothing was written for `heartbeatInterval`, so no frame lasts longer than that.
public struct FrameGate {
    public let heartbeatInterval: CMTime
    public private(set) var lastAppended: CMTime = .invalid

    public init(heartbeatInterval: CMTime) {
        self.heartbeatInterval = heartbeatInterval
    }

    public var hasStarted: Bool { lastAppended.isValid }

    /// Returns true when the frame should be written, and records it as the latest appended frame.
    public mutating func decide(status: FrameStatus, presentationTime: CMTime) -> Bool {
        guard status == .complete, presentationTime.isValid else { return false }
        if hasStarted && CMTimeCompare(presentationTime, lastAppended) <= 0 { return false }
        lastAppended = presentationTime
        return true
    }

    public func heartbeatDue(now: CMTime) -> Bool {
        guard hasStarted else { return false }
        return CMTimeCompare(CMTimeSubtract(now, lastAppended), heartbeatInterval) >= 0
    }

    public mutating func noteAppended(at time: CMTime) {
        lastAppended = time
    }
}

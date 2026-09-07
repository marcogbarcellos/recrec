import Foundation
import RecRecCore

enum RecorderState: Equatable {
    case idle
    case preparing
    case recording(since: Date)
    case stopping
}

@MainActor
protocol Recorder: AnyObject {
    var state: RecorderState { get }
    var onStateChange: ((RecorderState) -> Void)? { get set }
    var onFinished: ((Result<RecordingResult, Error>) -> Void)? { get set }
    func start(settings: RecordingSettings) async throws
    func stop() async
}

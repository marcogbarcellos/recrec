import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Equatable {
    case h264, hevc
}

public enum Container: String, Codable, CaseIterable, Equatable {
    case mp4, mov
    public var fileExtension: String { rawValue }
}

public enum QualityTier: String, Codable, CaseIterable, Equatable {
    case small, balanced, high
}

public enum ResolutionScale: String, Codable, CaseIterable, Equatable {
    /// Native display pixels (2x on Retina displays).
    case retina
    /// Logical points (1x): about half the file size, softer text.
    case standard
}

public struct RecordingSettings: Codable, Equatable {
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool
    public var showsCursor: Bool
    public var quality: QualityTier
    public var codec: VideoCodec
    public var container: Container
    public var frameRate: Int
    public var resolution: ResolutionScale
    public var revealInFinder: Bool
    /// Display to record; nil means "the display under the mouse".
    public var pinnedDisplayID: UInt32?
    public var saveDirectory: URL

    public static let frameRateChoices = [15, 24, 30, 60]

    public static let defaultSaveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/RecRec", isDirectory: true)

    public static let defaults = RecordingSettings(
        microphoneEnabled: false,
        systemAudioEnabled: false,
        showsCursor: true,
        quality: .balanced,
        codec: .hevc,
        container: .mp4,
        frameRate: 30,
        resolution: .retina,
        revealInFinder: true,
        pinnedDisplayID: nil,
        saveDirectory: defaultSaveDirectory
    )

    public init(microphoneEnabled: Bool, systemAudioEnabled: Bool, showsCursor: Bool, quality: QualityTier,
                codec: VideoCodec, container: Container, frameRate: Int, resolution: ResolutionScale,
                revealInFinder: Bool, pinnedDisplayID: UInt32?, saveDirectory: URL) {
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.showsCursor = showsCursor
        self.quality = quality
        self.codec = codec
        self.container = container
        self.frameRate = frameRate
        self.resolution = resolution
        self.revealInFinder = revealInFinder
        self.pinnedDisplayID = pinnedDisplayID
        self.saveDirectory = saveDirectory
    }
}

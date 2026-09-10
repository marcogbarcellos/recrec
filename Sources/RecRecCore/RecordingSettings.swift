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

public enum CameraCorner: String, Codable, CaseIterable, Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public enum CameraBubbleSize: String, Codable, CaseIterable, Equatable {
    case small, medium, large

    /// Bubble diameter in points.
    public var diameter: CGFloat {
        switch self {
        case .small: return 160
        case .medium: return 220
        case .large: return 300
        }
    }
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
    /// Loom-style floating camera bubble; visible whenever enabled, captured as part of the screen.
    public var cameraEnabled: Bool
    public var cameraCorner: CameraCorner
    public var cameraSize: CameraBubbleSize
    public var cameraMirrored: Bool

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
        saveDirectory: defaultSaveDirectory,
        cameraEnabled: false,
        cameraCorner: .topRight,
        cameraSize: .medium,
        cameraMirrored: true
    )

    public init(microphoneEnabled: Bool, systemAudioEnabled: Bool, showsCursor: Bool, quality: QualityTier,
                codec: VideoCodec, container: Container, frameRate: Int, resolution: ResolutionScale,
                revealInFinder: Bool, pinnedDisplayID: UInt32?, saveDirectory: URL,
                cameraEnabled: Bool = false, cameraCorner: CameraCorner = .topRight,
                cameraSize: CameraBubbleSize = .medium, cameraMirrored: Bool = true) {
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
        self.cameraEnabled = cameraEnabled
        self.cameraCorner = cameraCorner
        self.cameraSize = cameraSize
        self.cameraMirrored = cameraMirrored
    }

    /// Every key falls back to its default so settings saved by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings.defaults
        microphoneEnabled = try c.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? d.microphoneEnabled
        systemAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? d.systemAudioEnabled
        showsCursor = try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? d.showsCursor
        quality = try c.decodeIfPresent(QualityTier.self, forKey: .quality) ?? d.quality
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        container = try c.decodeIfPresent(Container.self, forKey: .container) ?? d.container
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        resolution = try c.decodeIfPresent(ResolutionScale.self, forKey: .resolution) ?? d.resolution
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? d.revealInFinder
        pinnedDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .pinnedDisplayID)
        saveDirectory = try c.decodeIfPresent(URL.self, forKey: .saveDirectory) ?? d.saveDirectory
        cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? d.cameraEnabled
        cameraCorner = try c.decodeIfPresent(CameraCorner.self, forKey: .cameraCorner) ?? d.cameraCorner
        cameraSize = try c.decodeIfPresent(CameraBubbleSize.self, forKey: .cameraSize) ?? d.cameraSize
        cameraMirrored = try c.decodeIfPresent(Bool.self, forKey: .cameraMirrored) ?? d.cameraMirrored
    }
}

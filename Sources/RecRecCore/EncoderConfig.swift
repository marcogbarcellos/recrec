import Foundation
import AVFoundation
import VideoToolbox

public enum AudioTrackKind: String, Equatable {
    case microphone, system
}

public struct CaptureGeometry: Equatable {
    /// Output video size in pixels (always even).
    public var width: Int
    public var height: Int
    /// Region of the display, in points, that is captured into width×height.
    public var sourceRect: CGRect
    /// True when the capture should run at the display's nominal (1x) resolution.
    public var usesNominalResolution: Bool

    public init(width: Int, height: Int, sourceRect: CGRect, usesNominalResolution: Bool) {
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
        self.usesNominalResolution = usesNominalResolution
    }
}

/// Encoder and capture parameters derived from the benchmark in docs/benchmarks/encoder-benchmark.md.
public enum EncoderConfig {
    /// Keyframe cadence in seconds of *written* frames (converted to a frame count so idle heartbeats stay cheap).
    public static let keyframeIntervalSeconds: Double = 10
    public static let heartbeatIntervalSeconds: Double = 2
    public static let fragmentIntervalSeconds: Double = 5
    public static let audioSampleRate: Double = 48_000
    /// Apple's hardware H.264 encoder does not accept frames larger than this; AVAssetWriter would silently
    /// fall back to a software encoder.
    public static let h264MaxSize = CGSize(width: 4096, height: 2304)

    public static func qualityValue(codec: VideoCodec, tier: QualityTier, scale: ResolutionScale) -> Double {
        switch (codec, scale, tier) {
        case (.hevc, .retina, .small): return 0.40
        case (.hevc, .retina, .balanced): return 0.50
        case (.hevc, .retina, .high): return 0.65
        case (.hevc, .standard, .small): return 0.50
        case (.hevc, .standard, .balanced): return 0.55
        case (.hevc, .standard, .high): return 0.70
        case (.h264, .retina, .small): return 0.45
        case (.h264, .retina, .balanced): return 0.50
        case (.h264, .retina, .high): return 0.65
        case (.h264, .standard, .small): return 0.50
        case (.h264, .standard, .balanced): return 0.60
        case (.h264, .standard, .high): return 0.70
        }
    }

    /// AVAssetWriterInput output settings for the video track.
    public static func videoSettings(codec: VideoCodec, tier: QualityTier, scale: ResolutionScale,
                                     width: Int, height: Int, frameRate: Int) -> [String: Any] {
        var compression: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: qualityValue(codec: codec, tier: tier, scale: scale),
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false,
            kVTCompressionPropertyKey_RealTime as String: true,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: frameRate * Int(keyframeIntervalSeconds),
            AVVideoExpectedSourceFrameRateKey: frameRate,
        ]
        let codecType: AVVideoCodecType
        switch codec {
        case .hevc:
            codecType = .hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .h264:
            codecType = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        return [
            AVVideoCodecKey: codecType.rawValue,
            AVVideoWidthKey: width & ~1,
            AVVideoHeightKey: height & ~1,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// AVAssetWriterInput output settings for an AAC audio track.
    public static func audioSettings(kind: AudioTrackKind) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: kind == .microphone ? 1 : 2,
            AVEncoderBitRateKey: kind == .microphone ? 64_000 : 128_000,
        ]
    }

    /// Output size and captured region for a display. Dimensions are made even by cropping a row/column,
    /// never by scaling, except when H.264 needs to fit inside `h264MaxSize`.
    public static func captureGeometry(pointSize: CGSize, pixelSize: CGSize, scale: ResolutionScale,
                                       codec: VideoCodec = .hevc) -> CaptureGeometry {
        let factor = pointSize.width > 0 ? pixelSize.width / pointSize.width : 1
        var geometry: CaptureGeometry
        switch scale {
        case .retina:
            let w = Int(pixelSize.width) & ~1
            let h = Int(pixelSize.height) & ~1
            geometry = CaptureGeometry(width: w, height: h,
                                       sourceRect: CGRect(x: 0, y: 0, width: Double(w) / factor, height: Double(h) / factor),
                                       usesNominalResolution: false)
        case .standard:
            let w = Int(pointSize.width) & ~1
            let h = Int(pointSize.height) & ~1
            geometry = CaptureGeometry(width: w, height: h,
                                       sourceRect: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)),
                                       usesNominalResolution: true)
        }
        if codec == .h264, Double(geometry.width) > h264MaxSize.width || Double(geometry.height) > h264MaxSize.height {
            let ratio = min(h264MaxSize.width / Double(geometry.width), h264MaxSize.height / Double(geometry.height))
            geometry.width = Int((Double(geometry.width) * ratio).rounded(.down)) & ~1
            geometry.height = Int((Double(geometry.height) * ratio).rounded(.down)) & ~1
        }
        return geometry
    }
}

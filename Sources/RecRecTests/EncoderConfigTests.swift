import Foundation
import AVFoundation
import VideoToolbox
import RecRecCore

func registerEncoderConfigTests(_ r: TestRunner) {
    r.test("quality table matches the benchmark decisions") {
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .small, scale: .retina), 0.40)
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .balanced, scale: .retina), 0.50)
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .high, scale: .retina), 0.65)
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .small, scale: .standard), 0.50)
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .balanced, scale: .standard), 0.55)
        try expectEqual(EncoderConfig.qualityValue(codec: .hevc, tier: .high, scale: .standard), 0.70)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .small, scale: .retina), 0.45)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .balanced, scale: .retina), 0.50)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .high, scale: .retina), 0.65)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .small, scale: .standard), 0.50)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .balanced, scale: .standard), 0.60)
        try expectEqual(EncoderConfig.qualityValue(codec: .h264, tier: .high, scale: .standard), 0.70)
    }

    r.test("video settings carry the spec keys and even dimensions") {
        let s = EncoderConfig.videoSettings(codec: .hevc, tier: .balanced, scale: .retina, width: 3456, height: 2233, frameRate: 30)
        try expectEqual(s[AVVideoCodecKey] as? String, AVVideoCodecType.hevc.rawValue)
        try expectEqual(s[AVVideoWidthKey] as? Int, 3456)
        try expectEqual(s[AVVideoHeightKey] as? Int, 2232)
        let c = s[AVVideoCompressionPropertiesKey] as! [String: Any]
        try expectEqual(c[kVTCompressionPropertyKey_Quality as String] as? Double, 0.50)
        try expectEqual(c[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] as? Bool, false)
        try expectEqual(c[AVVideoAllowFrameReorderingKey] as? Bool, false)
        try expectEqual(c[AVVideoMaxKeyFrameIntervalKey] as? Int, 300)
        try expect(c[AVVideoMaxKeyFrameIntervalDurationKey] == nil, "keyframes are counted in frames, not seconds")
        try expectEqual(c[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
        try expectEqual(c[kVTCompressionPropertyKey_RealTime as String] as? Bool, true)
        try expectEqual(c[AVVideoProfileLevelKey] as? String, kVTProfileLevel_HEVC_Main_AutoLevel as String)
        try expect(c[AVVideoAverageBitRateKey] == nil, "no bitrate key in quality mode")
        let color = s[AVVideoColorPropertiesKey] as! [String: String]
        try expectEqual(color[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_709_2)
        try expectEqual(color[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_709_2)
        try expectEqual(color[AVVideoYCbCrMatrixKey], AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    r.test("h264 settings use High profile and CABAC") {
        let s = EncoderConfig.videoSettings(codec: .h264, tier: .high, scale: .standard, width: 1728, height: 1116, frameRate: 60)
        let c = s[AVVideoCompressionPropertiesKey] as! [String: Any]
        try expectEqual(s[AVVideoCodecKey] as? String, AVVideoCodecType.h264.rawValue)
        try expectEqual(c[AVVideoProfileLevelKey] as? String, AVVideoProfileLevelH264HighAutoLevel)
        try expectEqual(c[AVVideoH264EntropyModeKey] as? String, AVVideoH264EntropyModeCABAC)
        try expectEqual(c[kVTCompressionPropertyKey_Quality as String] as? Double, 0.70)
        try expectEqual(c[AVVideoMaxKeyFrameIntervalKey] as? Int, 600)
    }

    r.test("audio settings: mic mono 64 kbps, system stereo 128 kbps, AAC 48 kHz") {
        let mic = EncoderConfig.audioSettings(kind: .microphone)
        try expectEqual(mic[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        try expectEqual(mic[AVSampleRateKey] as? Double, 48000)
        try expectEqual(mic[AVNumberOfChannelsKey] as? Int, 1)
        try expectEqual(mic[AVEncoderBitRateKey] as? Int, 64_000)
        let sys = EncoderConfig.audioSettings(kind: .system)
        try expectEqual(sys[AVNumberOfChannelsKey] as? Int, 2)
        try expectEqual(sys[AVEncoderBitRateKey] as? Int, 128_000)
    }

    r.test("capture geometry: retina keeps pixels, standard crops odd rows, both even") {
        let points = CGSize(width: 1728, height: 1117)
        let pixels = CGSize(width: 3456, height: 2234)
        let retina = EncoderConfig.captureGeometry(pointSize: points, pixelSize: pixels, scale: .retina)
        try expectEqual(retina.width, 3456)
        try expectEqual(retina.height, 2234)
        try expectEqual(retina.sourceRect, CGRect(x: 0, y: 0, width: 1728, height: 1117))
        try expectEqual(retina.usesNominalResolution, false)

        let standard = EncoderConfig.captureGeometry(pointSize: points, pixelSize: pixels, scale: .standard)
        try expectEqual(standard.width, 1728)
        try expectEqual(standard.height, 1116)
        try expectEqual(standard.sourceRect, CGRect(x: 0, y: 0, width: 1728, height: 1116))
        try expectEqual(standard.usesNominalResolution, true)

        let oddRetina = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1281, height: 801), pixelSize: CGSize(width: 2562, height: 1602), scale: .retina)
        try expectEqual(oddRetina.width, 2562)
        try expectEqual(oddRetina.height, 1602)

        let nonRetina = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1919, height: 1080), pixelSize: CGSize(width: 1919, height: 1080), scale: .retina)
        try expectEqual(nonRetina.width, 1918)
        try expectEqual(nonRetina.height, 1080)
        try expectEqual(nonRetina.sourceRect, CGRect(x: 0, y: 0, width: 1918, height: 1080))
    }

    r.test("capture geometry: h264 5K display is downscaled to fit 4096x2304, hevc is not") {
        let points = CGSize(width: 2560, height: 1440)
        let pixels = CGSize(width: 5120, height: 2880)
        let h264 = EncoderConfig.captureGeometry(pointSize: points, pixelSize: pixels, scale: .retina, codec: .h264)
        try expectEqual(h264.width, 4096)
        try expectEqual(h264.height, 2304)
        try expectEqual(h264.sourceRect, CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let hevc = EncoderConfig.captureGeometry(pointSize: points, pixelSize: pixels, scale: .retina, codec: .hevc)
        try expectEqual(hevc.width, 5120)
        try expectEqual(hevc.height, 2880)
        let standard = EncoderConfig.captureGeometry(pointSize: points, pixelSize: pixels, scale: .standard, codec: .h264)
        try expectEqual(standard.width, 2560)
        try expectEqual(standard.height, 1440)
    }
}

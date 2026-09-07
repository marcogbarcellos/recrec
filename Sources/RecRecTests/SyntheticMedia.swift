import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

enum SyntheticMedia {
    /// A 4:2:0 video-range pixel buffer whose luma pattern depends on `frame`, so consecutive frames differ.
    static func pixelBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        // Vertical stripes 64 px wide that shift with `frame`; built once per row then copied (fast in debug builds).
        var col = 0
        while col < width {
            let stripe = ((col / 64) + frame) % 2 == 0
            let run = min(64, width - col)
            memset(luma + col, stripe ? 200 : 40, run)
            col += run
        }
        for row in 1..<height {
            memcpy(luma + row * lumaStride, luma, width)
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Mono Float32 PCM sample buffer carrying a 440 Hz tone.
    static func audioSampleBuffer(startTime: CMTime, frames: Int, sampleRate: Double = 48_000) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferAssureBlockMemory(block!)
        var samples = [Float](repeating: 0, count: frames)
        let startFrame = CMTimeGetSeconds(startTime) * sampleRate
        for i in 0..<frames {
            samples[i] = 0.2 * sinf(Float(2 * Double.pi * 440 * (startFrame + Double(i)) / sampleRate))
        }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: startTime, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        return sampleBuffer!
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recrec-test-\(UUID().uuidString).\(ext)")
    }

    /// Deletes a test output unless KEEP_TEST_FILES is set (then prints the path for manual inspection).
    static func cleanup(_ url: URL) {
        if ProcessInfo.processInfo.environment["KEEP_TEST_FILES"] != nil {
            print("      kept \(url.path)")
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    struct AssetInfo {
        var duration: Double
        var videoFrames: Int
        var hasAudio: Bool
        var codec: String
        var width: Int
        var height: Int
    }

    static func inspect(_ url: URL) async throws -> AssetInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw TestFailure(message: "no video track in \(url.lastPathComponent)", file: #filePath, line: #line)
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video.load(.naturalSize)
        let descriptions = try await video.load(.formatDescriptions)
        let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0).fourCharString } ?? "????"
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        // Passthrough reading of fragmented files can yield empty sample buffers; count real samples only.
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetTotalSampleSize(sample) > 0 { frames += CMSampleBufferGetNumSamples(sample) }
        }
        return AssetInfo(duration: CMTimeGetSeconds(duration), videoFrames: frames, hasAudio: !audio.isEmpty,
                         codec: codec, width: Int(size.width), height: Int(size.height))
    }

    static func countAtoms(_ url: URL, _ atom: String) throws -> Int {
        let data = try Data(contentsOf: url)
        let needle = Data(atom.utf8)
        var count = 0
        var range = data.startIndex..<data.endIndex
        while let found = data.range(of: needle, in: range) {
            count += 1
            range = found.upperBound..<data.endIndex
        }
        return count
    }
}

extension FourCharCode {
    var fourCharString: String {
        let bytes = [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

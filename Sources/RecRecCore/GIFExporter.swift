import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct GIFExportOptions {
    public var framesPerSecond: Int
    public var maxWidth: Int

    public init(framesPerSecond: Int = 10, maxWidth: Int = 1200) {
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
    }
}

/// Converts a recording into an animated GIF: decodes the video once, sequentially (our keyframes are far
/// apart, so seeking per frame would be slow), samples it at `framesPerSecond`, scales frames to at most
/// `maxWidth` pixels wide and loops forever. GIFs are large per second, so this is meant for short clips.
public enum GIFExporter {
    /// Returns the number of frames written. The output file is removed on failure.
    @discardableResult
    public static func export(video: URL, to gifURL: URL, options: GIFExportOptions = GIFExportOptions(),
                              progress: ((Double) -> Void)? = nil) async throws -> Int {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecRecError.exportFailed("no video track in \(video.lastPathComponent)")
        }
        let naturalSize = try await track.load(.naturalSize)
        let scale = min(1, Double(options.maxWidth) / Double(naturalSize.width))
        let targetSize = CGSize(width: (naturalSize.width * scale).rounded(), height: (naturalSize.height * scale).rounded())
        let frameDuration = 1.0 / Double(max(1, options.framesPerSecond))
        let frameCount = max(1, Int((duration / frameDuration).rounded(.down)))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecRecError.exportFailed("cannot decode \(video.lastPathComponent)") }
        reader.add(output)
        guard reader.startReading() else {
            throw RecRecError.exportFailed(reader.error?.localizedDescription ?? "cannot decode \(video.lastPathComponent)")
        }

        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw RecRecError.exportFailed("could not create \(gifURL.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDuration]] as CFDictionary

        var written = 0
        var nextTarget = 0
        var current: CVPixelBuffer?

        func emit(_ pixelBuffer: CVPixelBuffer) throws {
            guard let image = scaledImage(from: pixelBuffer, to: targetSize) else {
                throw RecRecError.exportFailed("could not convert a frame")
            }
            CGImageDestinationAddImage(destination, image, frameProperties)
            written += 1
            nextTarget += 1
            progress?(Double(written) / Double(frameCount))
        }

        do {
            // Each decoded frame is shown until the next one starts; emit every 1/fps target inside that span.
            while let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                while let shown = current, nextTarget < frameCount, Double(nextTarget) * frameDuration < pts {
                    try emit(shown)
                }
                current = pixelBuffer
            }
            if reader.status == .failed {
                throw RecRecError.exportFailed(reader.error?.localizedDescription ?? "decode failed")
            }
            while let shown = current, nextTarget < frameCount {
                try emit(shown)
            }
            guard written > 0 else { throw RecRecError.exportFailed("no frames decoded") }
            guard CGImageDestinationFinalize(destination) else {
                throw RecRecError.exportFailed("could not finalize \(gifURL.lastPathComponent)")
            }
        } catch {
            try? FileManager.default.removeItem(at: gifURL)
            throw (error as? RecRecError) ?? RecRecError.exportFailed(error.localizedDescription)
        }
        progress?(1)
        return written
    }

    /// Wraps a BGRA pixel buffer as a CGImage and draws it into a bitmap of `size`.
    private static func scaledImage(from pixelBuffer: CVPixelBuffer, to size: CGSize) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let source = CGContext(data: base, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                     space: colorSpace, bitmapInfo: bitmapInfo),
              let sourceImage = source.makeImage() else { return nil }
        let width = Int(size.width), height = Int(size.height)
        if width == sourceImage.width && height == sourceImage.height { return sourceImage }
        guard let target = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        target.interpolationQuality = .high
        target.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return target.makeImage()
    }
}

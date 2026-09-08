// Generates the RecRec app icon (AppIcon.icns) and README logo PNGs with CoreGraphics.
// usage: swift tools/icon/make-icon.swift <output-dir>
// Design: macOS squircle in dark slate, a thin light ring and a red record dot (the same glyph the
// menu-bar item uses). Mirrored by docs/assets/logo.svg.
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func drawIcon(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = CGFloat(size) / 1024          // design units → pixels
    let center = CGPoint(x: 512 * u, y: 512 * u)

    // Squircle background (Apple's icon grid: 824 pt square inset by 100 pt).
    let square = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = CGPath(roundedRect: square, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 28 * u, color: color(0x000000, alpha: 0.35))
    context.addPath(squircle)
    context.setFillColor(color(0x1A1D24))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let background = CGGradient(colorsSpace: colorSpace, colors: [color(0x323846), color(0x121419)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
    // Soft top highlight.
    let sheen = CGGradient(colorsSpace: colorSpace, colors: [color(0xFFFFFF, alpha: 0.10), color(0xFFFFFF, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.maxY - 300 * u), options: [])
    context.restoreGState()

    // Ring.
    context.setStrokeColor(color(0xF2F2F2))
    context.setLineWidth(46 * u)
    context.addArc(center: center, radius: 300 * u, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    context.strokePath()

    // Record dot with a glow and a radial highlight.
    let dotRect = CGRect(x: center.x - 205 * u, y: center.y - 205 * u, width: 410 * u, height: 410 * u)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 30 * u, color: color(0xFF3B30, alpha: 0.55))
    context.setFillColor(color(0xE0271C))
    context.fillEllipse(in: dotRect)
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: dotRect)
    context.clip()
    let dot = CGGradient(colorsSpace: colorSpace, colors: [color(0xFF7A70), color(0xFF3B30), color(0xD9241A)] as CFArray, locations: [0, 0.45, 1])!
    context.drawRadialGradient(dot, startCenter: CGPoint(x: center.x - 70 * u, y: center.y + 90 * u), startRadius: 0,
                               endCenter: center, endRadius: 230 * u, options: [.drawsAfterEndLocation])
    context.restoreGState()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    writePNG(drawIcon(size: size), to: iconset.appendingPathComponent("icon_\(name).png"))
}
writePNG(drawIcon(size: 512), to: outputDirectory.appendingPathComponent("logo-512.png"))
writePNG(drawIcon(size: 128), to: outputDirectory.appendingPathComponent("logo-128.png"))
print("wrote \(iconset.path) and logo PNGs")

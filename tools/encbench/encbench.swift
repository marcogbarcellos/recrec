// Encoder benchmark tool for RecRec (developer utility, not part of the app).
// Renders synthetic "desktop" frames (editor window, typing, scrolling, mouse, window drag, static)
// and feeds the same frames to several AVAssetWriter configurations at once, so settings can be
// compared on identical input without Screen Recording permission. See docs/benchmarks/encoder-benchmark.md.
// usage: swiftc -O -o encbench encbench.swift && ./encbench --scale 2 --seconds 60 --fps 30 --set core --outdir out --ref 5,15,45
import AppKit
import AVFoundation
import VideoToolbox
import CoreText
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - args
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
let scale = Double(opt("--scale", "2"))!
let seconds = Double(opt("--seconds", "60"))!
let fps = Int(opt("--fps", "30"))!
let setName = opt("--set", "core")
let outDir = opt("--outdir", ".")
let refTimes = opt("--ref", "").split(separator: ",").compactMap { Double($0) }
let baseW = 1728, baseH = 1117 // logical points of the user's 16" MBP
let W = Int(Double(baseW) * scale) & ~1, H = Int(Double(baseH) * scale) & ~1
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - configs
enum Codec { case h264, hevc }
struct Config {
    var name: String
    var codec: Codec
    var quality: Double? = nil
    var bitrate: Int? = nil
    var vfr: Bool = true
    var keyint: Double = 10
    var reorder: Bool = true
    var speedPrio: Bool? = nil
    var realtime: Bool = true
    var heartbeat: Double? = nil   // seconds; re-append last frame if idle longer than this
    var maxQP: Int? = nil
    var minQP: Int? = nil
    var dataRateLimit: (bytesPerSec: Int, window: Double)? = nil
    var fragment: Double? = nil  // movieFragmentInterval seconds
}
func configs(_ set: String) -> [Config] {
    switch set {
    case "smoke":
        return [Config(name: "hevc_q50_vfr", codec: .hevc, quality: 0.5)]
    case "core":
        return [
            Config(name: "qt_like_h264_30M_cfr", codec: .h264, bitrate: 30_000_000, vfr: false, keyint: 1, reorder: false),
            Config(name: "h264_8M_cfr", codec: .h264, bitrate: 8_000_000, vfr: false),
            Config(name: "h264_q50_cfr", codec: .h264, quality: 0.5, vfr: false),
            Config(name: "h264_q50_vfr", codec: .h264, quality: 0.5),
            Config(name: "h264_q60_vfr", codec: .h264, quality: 0.6),
            Config(name: "h264_q70_vfr", codec: .h264, quality: 0.7),
            Config(name: "h264_3M_vfr", codec: .h264, bitrate: 3_000_000),
            Config(name: "hevc_q40_vfr", codec: .hevc, quality: 0.4),
            Config(name: "hevc_q50_vfr", codec: .hevc, quality: 0.5),
            Config(name: "hevc_q60_vfr", codec: .hevc, quality: 0.6),
            Config(name: "hevc_q70_vfr", codec: .hevc, quality: 0.7),
            Config(name: "hevc_q50_cfr", codec: .hevc, quality: 0.5, vfr: false),
            Config(name: "hevc_2M_vfr", codec: .hevc, bitrate: 2_000_000),
        ]
    case "variants":
        return [
            Config(name: "hevc_q50_vfr_base", codec: .hevc, quality: 0.5),
            Config(name: "hevc_q50_vfr_key2", codec: .hevc, quality: 0.5, keyint: 2),
            Config(name: "hevc_q50_vfr_key30", codec: .hevc, quality: 0.5, keyint: 30),
            Config(name: "hevc_q50_vfr_noreorder", codec: .hevc, quality: 0.5, reorder: false),
            Config(name: "hevc_q50_vfr_speedprio0", codec: .hevc, quality: 0.5, speedPrio: false),
            Config(name: "hevc_q50_vfr_speedprio1", codec: .hevc, quality: 0.5, speedPrio: true),
            Config(name: "hevc_q50_vfr_nonrealtime", codec: .hevc, quality: 0.5, realtime: false),
            Config(name: "hevc_q50_vfr_hb1", codec: .hevc, quality: 0.5, heartbeat: 1.0),
            Config(name: "hevc_q50_vfr_maxqp40", codec: .hevc, quality: 0.5, maxQP: 40),
            Config(name: "hevc_q50_vfr_cap3M", codec: .hevc, quality: 0.5, dataRateLimit: (375_000, 1.0)),
            Config(name: "h264_q50_vfr_speedprio0", codec: .h264, quality: 0.5, speedPrio: false),
            Config(name: "h264_q50_vfr_nonrealtime", codec: .h264, quality: 0.5, realtime: false),
        ]
    case "frag":
        return [
            Config(name: "hevc_q50_sp0_nofrag", codec: .hevc, quality: 0.50, speedPrio: false),
            Config(name: "hevc_q50_sp0_frag2", codec: .hevc, quality: 0.50, speedPrio: false, fragment: 2),
            Config(name: "hevc_q50_sp0_frag5", codec: .hevc, quality: 0.50, speedPrio: false, fragment: 5),
            Config(name: "hevc_q50_sp0_frag10", codec: .hevc, quality: 0.50, speedPrio: false, fragment: 10),
            Config(name: "hevc_q50_sp0_frag5_hb1", codec: .hevc, quality: 0.50, speedPrio: false, heartbeat: 1.0, fragment: 5),
        ]
    case "sweepA":
        return [
            Config(name: "hevc_q40_sp0", codec: .hevc, quality: 0.40, speedPrio: false),
            Config(name: "hevc_q45_sp0", codec: .hevc, quality: 0.45, speedPrio: false),
            Config(name: "hevc_q50_sp0", codec: .hevc, quality: 0.50, speedPrio: false),
            Config(name: "hevc_q55_sp0", codec: .hevc, quality: 0.55, speedPrio: false),
            Config(name: "hevc_q60_sp0", codec: .hevc, quality: 0.60, speedPrio: false),
            Config(name: "hevc_q65_sp0", codec: .hevc, quality: 0.65, speedPrio: false),
            Config(name: "hevc_q70_sp0", codec: .hevc, quality: 0.70, speedPrio: false),
        ]
    case "sweepB":
        return [
            Config(name: "hevc_q50_sp0_noreorder", codec: .hevc, quality: 0.50, reorder: false, speedPrio: false),
            Config(name: "hevc_q60_sp0_noreorder", codec: .hevc, quality: 0.60, reorder: false, speedPrio: false),
            Config(name: "hevc_q50_sp0_key30", codec: .hevc, quality: 0.50, keyint: 30, speedPrio: false),
            Config(name: "h264_q45", codec: .h264, quality: 0.45),
            Config(name: "h264_q55", codec: .h264, quality: 0.55),
            Config(name: "h264_q65", codec: .h264, quality: 0.65),
            Config(name: "h264_q50_noreorder", codec: .h264, quality: 0.50, reorder: false),
        ]
    case "sweep":
        return [
            Config(name: "hevc_q40_sp0", codec: .hevc, quality: 0.40, speedPrio: false),
            Config(name: "hevc_q45_sp0", codec: .hevc, quality: 0.45, speedPrio: false),
            Config(name: "hevc_q50_sp0", codec: .hevc, quality: 0.50, speedPrio: false),
            Config(name: "hevc_q55_sp0", codec: .hevc, quality: 0.55, speedPrio: false),
            Config(name: "hevc_q60_sp0", codec: .hevc, quality: 0.60, speedPrio: false),
            Config(name: "hevc_q65_sp0", codec: .hevc, quality: 0.65, speedPrio: false),
            Config(name: "hevc_q70_sp0", codec: .hevc, quality: 0.70, speedPrio: false),
            Config(name: "hevc_q50_sp0_noreorder", codec: .hevc, quality: 0.50, reorder: false, speedPrio: false),
            Config(name: "hevc_q60_sp0_noreorder", codec: .hevc, quality: 0.60, reorder: false, speedPrio: false),
            Config(name: "hevc_q50_sp0_key30", codec: .hevc, quality: 0.50, keyint: 30, speedPrio: false),
            Config(name: "h264_q45", codec: .h264, quality: 0.45),
            Config(name: "h264_q55", codec: .h264, quality: 0.55),
            Config(name: "h264_q65", codec: .h264, quality: 0.65),
            Config(name: "h264_q50_noreorder", codec: .h264, quality: 0.50, reorder: false),
        ]
    default: fatalError("unknown set")
    }
}

// MARK: - writer
final class Writer {
    let cfg: Config
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var started = false
    var lastAppendedPTS = CMTime.invalid
    var lastBuffer: CVPixelBuffer?
    var appended = 0
    init(cfg: Config, dir: String) throws {
        self.cfg = cfg
        url = URL(fileURLWithPath: dir).appendingPathComponent("\(cfg.name)_\(W)x\(H).mp4")
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        if let fr = cfg.fragment { writer.movieFragmentInterval = CMTime(seconds: fr, preferredTimescale: 600) }
        var comp: [String: Any] = [
            AVVideoMaxKeyFrameIntervalDurationKey: cfg.keyint,
            AVVideoAllowFrameReorderingKey: cfg.reorder,
            AVVideoExpectedSourceFrameRateKey: fps,
            kVTCompressionPropertyKey_RealTime as String: cfg.realtime,
        ]
        switch cfg.codec {
        case .h264:
            comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            comp[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        case .hevc:
            comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        if let q = cfg.quality { comp[kVTCompressionPropertyKey_Quality as String] = q }
        if let b = cfg.bitrate { comp[AVVideoAverageBitRateKey] = b }
        if let s = cfg.speedPrio { comp[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = s }
        if let m = cfg.maxQP { comp[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] = m }
        if let m = cfg.minQP { comp[kVTCompressionPropertyKey_MinAllowedFrameQP as String] = m }
        if let d = cfg.dataRateLimit { comp[kVTCompressionPropertyKey_DataRateLimits as String] = [d.bytesPerSec, d.window] }
        let settings: [String: Any] = [
            AVVideoCodecKey: cfg.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: comp,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = cfg.realtime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "w", code: 1) }
    }
    func offer(_ pb: CVPixelBuffer, pts: CMTime, changed: Bool) {
        if !started { writer.startSession(atSourceTime: pts); started = true }
        var shouldAppend = changed || !cfg.vfr || !lastAppendedPTS.isValid
        if !shouldAppend, let hb = cfg.heartbeat, CMTimeGetSeconds(pts - lastAppendedPTS) >= hb { shouldAppend = true }
        guard shouldAppend else { return }
        var spins = 0
        while !input.isReadyForMoreMediaData { if writer.status != .writing { return }; usleep(500); spins += 1; if spins > 60000 { print("stall \(cfg.name)"); return } }
        if !adaptor.append(pb, withPresentationTime: pts) { print("append failed \(cfg.name): \(writer.error?.localizedDescription ?? "?")") }
        lastAppendedPTS = pts; lastBuffer = pb; appended += 1
    }
    func finish(endPTS: CMTime, group: DispatchGroup) {
        // final frame so the file's duration matches the session length even if the tail was idle
        if let lb = lastBuffer, CMTimeCompare(endPTS, lastAppendedPTS) > 0, writer.status == .writing {
            var spins = 0
            while !input.isReadyForMoreMediaData && writer.status == .writing && spins < 20000 { usleep(500); spins += 1 }
            if writer.status == .writing && input.isReadyForMoreMediaData { _ = adaptor.append(lb, withPresentationTime: endPTS); appended += 1 }
        }
        if writer.status != .writing { print("writer \(cfg.name) status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "-")"); return }
        input.markAsFinished()
        writer.endSession(atSourceTime: endPTS)
        group.enter()
        writer.finishWriting { group.leave() }
    }
}

// MARK: - synthetic desktop renderer
struct Rng { var s: UInt64 = 0x9E3779B97F4A7C15; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }; mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
let keywords = ["func", "let", "var", "if", "else", "return", "guard", "struct", "class", "import", "for", "in", "while", "switch", "case", "throws", "async", "await"]
let idents = ["writer", "config", "frame", "buffer", "stream", "display", "pixel", "timestamp", "encoder", "session", "output", "sample", "queue", "handler", "delegate", "result", "count", "index", "value", "error"]
func makeLine(_ r: inout Rng, i: Int) -> NSAttributedString {
    let s = NSMutableAttributedString()
    let font = NSFont(name: "Menlo", size: 13 * scale) ?? NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
    func add(_ t: String, _ c: NSColor) { s.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
    let indent = String(repeating: "    ", count: r.int(4))
    add(indent, .black)
    switch r.int(6) {
    case 0: add("// " + (0..<r.int(6) + 2).map { _ in idents[r.int(idents.count)] }.joined(separator: " "), NSColor(red: 0.42, green: 0.48, blue: 0.42, alpha: 1))
    case 1: add(keywords[r.int(keywords.count)] + " ", NSColor(red: 0.61, green: 0.13, blue: 0.58, alpha: 1)); add(idents[r.int(idents.count)] + "(", .black); add(idents[r.int(idents.count)] + ": ", .black); add(idents[r.int(idents.count)], NSColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)); add(") {", .black)
    case 2: add("let ", NSColor(red: 0.61, green: 0.13, blue: 0.58, alpha: 1)); add(idents[r.int(idents.count)] + " = \"", .black); add((0..<r.int(4) + 1).map { _ in idents[r.int(idents.count)] }.joined(separator: " "), NSColor(red: 0.77, green: 0.1, blue: 0.09, alpha: 1)); add("\"", .black)
    case 3: add("}", .black)
    case 4: add(idents[r.int(idents.count)] + "." + idents[r.int(idents.count)] + "(" + idents[r.int(idents.count)] + ", " + idents[r.int(idents.count)] + ": " + String(r.int(4096)) + ")", .black)
    default: add("return " , NSColor(red: 0.61, green: 0.13, blue: 0.58, alpha: 1)); add(idents[r.int(idents.count)] + " + " + String(r.int(100)), .black)
    }
    return s
}
func makeContext(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
    CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}
let lineH = Int(18 * scale)
let docLines = 900
let editorW = W - Int(60 * scale) * 2 - Int(220 * scale)
let docH = docLines * lineH
let docImage: CGImage = {
    let ctx = makeContext(editorW, docH)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: editorW, height: docH))
    var r = Rng()
    for i in 0..<docLines {
        let line = CTLineCreateWithAttributedString(makeLine(&r, i: i))
        ctx.textPosition = CGPoint(x: 60 * scale, y: CGFloat(docH - (i + 1) * lineH) + 5 * scale)
        CTLineDraw(line, ctx)
        // line numbers
        let num = NSAttributedString(string: String(format: "%4d", i + 1), attributes: [.font: NSFont(name: "Menlo", size: 11 * scale)!, .foregroundColor: NSColor.gray])
        ctx.textPosition = CGPoint(x: 8 * scale, y: CGFloat(docH - (i + 1) * lineH) + 5 * scale)
        CTLineDraw(CTLineCreateWithAttributedString(num), ctx)
    }
    return ctx.makeImage()!
}()
let bgGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(red: 0.12, green: 0.22, blue: 0.55, alpha: 1), CGColor(red: 0.55, green: 0.25, blue: 0.6, alpha: 1), CGColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
let dockColors: [CGColor] = (0..<14).map { (i: Int) -> CGColor in
    let r: Double = Double((i * 37) % 100) / 100.0
    let g: Double = Double((i * 59) % 100) / 100.0
    let b: Double = Double((i * 83) % 100) / 100.0
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

struct Scene { var scroll: Int; var winDX: Int; var mouse: CGPoint; var typed: Int; var changed: Bool }
func scene(t: Double, prevT: Double?) -> Scene {
    let s = scale
    var sc = Scene(scroll: 0, winDX: 0, mouse: CGPoint(x: 900 * s, y: 600 * s), typed: 0, changed: prevT == nil)
    switch t {
    case ..<10:  // typing: 4 chars/s
        sc.typed = Int(t * 4); if let p = prevT, Int(p * 4) != sc.typed { sc.changed = true }
    case ..<20:  // smooth scroll
        sc.typed = 40; sc.scroll = Int((t - 10) * 240 * s); sc.changed = true
    case ..<30:  // static
        sc.typed = 40; sc.scroll = Int(10 * 240 * s)
    case ..<40:  // mouse circle
        sc.typed = 40; sc.scroll = Int(10 * 240 * s); sc.changed = true
        let a = (t - 30) * 2 * Double.pi / 4; sc.mouse = CGPoint(x: (900 + 300 * cos(a)) * s, y: (600 + 250 * sin(a)) * s)
    case ..<50:  // window drag
        sc.typed = 40; sc.scroll = Int(10 * 240 * s); sc.changed = true; sc.winDX = Int((t - 40) * 60 * s)
    default:     // static
        sc.typed = 40; sc.scroll = Int(10 * 240 * s); sc.winDX = Int(10 * 60 * s)
    }
    return sc
}
let typedText = "let recorder = ScreenRecorder(display: main, options: options) // small"
func render(_ ctx: CGContext, _ sc: Scene) {
    let s = scale
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * s, y: Double(H) - (y + h) * s, width: w * s, height: h * s) }
    // wallpaper
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
    // menu bar
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 0.95)); ctx.fill(rect(0, 0, Double(baseW), 24))
    let menuFont = NSFont.systemFont(ofSize: 13 * s, weight: .semibold)
    var x = 20.0
    for item in ["", "Editor", "File", "Edit", "View", "Go", "Window", "Help"] {
        let a = NSAttributedString(string: item.isEmpty ? "\u{F8FF}" : item, attributes: [.font: menuFont, .foregroundColor: NSColor.black])
        ctx.textPosition = CGPoint(x: x * s, y: Double(H) - 17 * s); CTLineDraw(CTLineCreateWithAttributedString(a), ctx); x += Double(item.count) * 9 + 22
    }
    // window
    let wx = 60.0 + Double(sc.winDX) / s, wy = 40.0
    let ww = Double(baseW) - 120, wh = Double(baseH) - 130
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(rect(wx, wy, ww, wh))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(gray: 0.86, alpha: 1)); ctx.fill(rect(wx, wy, ww, 28))
    for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() {
        ctx.setFillColor(c); ctx.fillEllipse(in: rect(wx + 12 + Double(i) * 20, wy + 8, 12, 12))
    }
    // sidebar
    ctx.setFillColor(CGColor(gray: 0.92, alpha: 1)); ctx.fill(rect(wx, wy + 28, 220, wh - 28))
    let sbFont = NSFont.systemFont(ofSize: 12 * s)
    for (i, name) in ["Sources", "  App.swift", "  Recorder.swift", "  Writer.swift", "  Settings.swift", "  Menu.swift", "Tests", "  WriterTests.swift", "Package.swift", "README.md"].enumerated() {
        let a = NSAttributedString(string: name, attributes: [.font: sbFont, .foregroundColor: NSColor.darkGray])
        ctx.textPosition = CGPoint(x: (wx + 16) * s, y: Double(H) - (wy + 52 + Double(i) * 22) * s); CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    }
    // editor: crop document
    let ex = wx + 220, ey = wy + 28, ew = ww - 220, eh = wh - 28
    let cropTop = min(max(sc.scroll, 0), docH - Int(eh * s))
    if let crop = docImage.cropping(to: CGRect(x: 0, y: docH - cropTop - Int(eh * s), width: Int(ew * s), height: Int(eh * s))) {
        ctx.draw(crop, in: rect(ex, ey, ew, eh))
    }
    // typed line at bottom of editor (typing phase)
    if sc.typed > 0 {
        let t = String(typedText.prefix(min(sc.typed, typedText.count)))
        let a = NSAttributedString(string: t + "|", attributes: [.font: NSFont(name: "Menlo", size: 13 * s)!, .foregroundColor: NSColor.black])
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.85, alpha: 1)); ctx.fill(rect(ex, ey + eh - 24, ew, 24))
        ctx.textPosition = CGPoint(x: (ex + 60) * s, y: Double(H) - (ey + eh - 7) * s); CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    }
    // dock
    ctx.setFillColor(CGColor(gray: 0.85, alpha: 0.6)); ctx.fill(rect(Double(baseW) / 2 - 340, Double(baseH) - 70, 680, 60))
    for (i, c) in dockColors.enumerated() { ctx.setFillColor(c); ctx.fill(rect(Double(baseW) / 2 - 330 + Double(i) * 48, Double(baseH) - 64, 44, 44)) }
    // cursor (arrow)
    ctx.saveGState()
    ctx.translateBy(x: sc.mouse.x, y: sc.mouse.y)
    let pts: [(Double, Double)] = [(0, 0), (0, -18), (5, -14), (8, -20), (11, -18), (8, -12), (13, -12)]
    let p = CGMutablePath()
    for (k, pt) in pts.enumerated() {
        let cg = CGPoint(x: CGFloat(pt.0 * s), y: CGFloat(pt.1 * s))
        if k == 0 { p.move(to: cg) } else { p.addLine(to: cg) }
    }
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.addPath(p); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.2 * s); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - run
var poolOut: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 12] as CFDictionary, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &poolOut)
let pool = poolOut!
let writers = try configs(setName).map { try Writer(cfg: $0, dir: outDir) }
let total = Int(seconds) * fps
var prevT: Double? = nil
var changedFrames = 0
let t0 = Date()
for i in 0..<total {
    let t = Double(i) / Double(fps)
    let sc = scene(t: t, prevT: prevT)
    prevT = t
    var pbOut: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
    let pb = pbOut!
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = makeContext(W, H, data: CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
    render(ctx, sc)
    if refTimes.contains(where: { abs($0 - t) < 0.5 / Double(fps) }) {
        let img = ctx.makeImage()!
        let u = URL(fileURLWithPath: outDir).appendingPathComponent("ref_\(Int(t))s_\(W)x\(H).png")
        let d = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    if sc.changed { changedFrames += 1 }
    let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
    for w in writers { w.offer(pb, pts: pts, changed: sc.changed) }
    if i % (fps * 10) == 0 { print("t=\(Int(t))s  gen \(String(format: "%.1f", Date().timeIntervalSince(t0)))s") }
}
let group = DispatchGroup()
let endPTS = CMTime(value: CMTimeValue(total), timescale: CMTimeScale(fps))
for w in writers { w.finish(endPTS: endPTS, group: group) }
group.wait()
print("\nframes=\(total) changed=\(changedFrames) res=\(W)x\(H) fps=\(fps) seconds=\(Int(seconds))")
print(String(format: "%-32s %10s %9s %8s %7s", "config", "bytes", "KB/s", "MB/min", "frames"))
for w in writers {
    let size = (try? FileManager.default.attributesOfItem(atPath: w.url.path)[.size] as? Int) ?? -1
    let status = w.writer.status == .completed ? "" : "STATUS=\(w.writer.status.rawValue) \(w.writer.error?.localizedDescription ?? "")"
    print(String(format: "%-32s %10d %9.1f %8.2f %7d ", w.cfg.name, size, Double(size) / seconds / 1024, Double(size) / seconds * 60 / 1_048_576, w.appended) + status)
}

# RecRec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build RecRec, a menu-bar macOS screen recorder that writes small constant-quality HEVC/H.264 MP4 files with idle-frame skipping and crash-safe fragments.

**Architecture:** A `RecRecCore` library holds everything testable without permissions (settings, encoder configuration, frame gating, the `AVAssetWriter` wrapper, naming, GIF export). The `RecRec` executable is a thin AppKit layer: status-item menu, ScreenCaptureKit stream orchestration, microphone capture, hotkey. A `RecRecTests` executable runs a custom harness because XCTest is unavailable with Command Line Tools.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, ScreenCaptureKit (macOS 14 API), AVFoundation/VideoToolbox, Carbon hotkeys, ServiceManagement, ImageIO. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-recrec-design.md`

**Status (2026-09-08):** executed inline, all 13 tasks done, 28 tests passing (`make test`), bundle built with `make app` (557 KB, idle RSS ≈ 44 MB). Deviations from the text below, all reflected in the code and spec: every appended frame carries an explicit one-frame duration and `finish(at:)` re-appends the last frame (AVAssetWriter trap found by research); keyframes use `AVVideoMaxKeyFrameIntervalKey` (frame count) instead of the duration key; default folder is `~/Movies/RecRec`; H.264 capped to 4096×2304; recording stops on system sleep; `RecordingWriter.cancel()` cleans up after a failed start; GIF export decodes sequentially with `AVAssetReader` instead of `AVAssetImageGenerator` (which was ~30× slower with long GOPs); the writer waits up to two frame durations for encoder readiness before dropping a frame. Live capture (Screen Recording permission) still needs the manual acceptance checklist in README.md.

## Global Constraints

- Toolchain: Command Line Tools 15.1, Swift 5.9.2, macOS SDK 14.2. No Xcode, no XCTest. Deployment target `macOS 14.0`.
- Do not use macOS 15+ APIs (`captureMicrophone`, `showMouseClicks`, `SCRecordingOutput`).
- No third-party packages. Frameworks are system frameworks only.
- Bundle identifier `com.barsmike.RecRec`; app name `RecRec`; default file name `Recording YYYY-MM-DD at HH.mm.ss.<ext>`.
- Defaults: microphone off, system audio off, cursor on, quality Balanced, format MP4+HEVC, 30 fps, Retina resolution, save to `~/Movies/RecRec`, reveal in Finder on, hotkey ⌃⌥⌘R.
- Encoder rules (spec §6): constant quality (`kVTCompressionPropertyKey_Quality`), `PrioritizeEncodingSpeedOverQuality = false`, `AllowFrameReordering = false`, keyframe interval `fps × 10` frames (count-based, `AVVideoMaxKeyFrameIntervalKey`), `RealTime = true`, 709 color tags, pixel format `420v`, `movieFragmentInterval = 5 s`, heartbeat 2 s, every appended frame carries an explicit duration of `1/fps`, `endSession` at the end of the final frame, mic AAC 64 kbps mono, system AAC 128 kbps stereo, H.264 capped to 4096×2304 by downscaling.
- Quality table (Small/Balanced/High): HEVC 2x 0.40/0.50/0.65; HEVC 1x 0.50/0.55/0.70; H.264 2x 0.45/0.50/0.65; H.264 1x 0.50/0.60/0.70.
- Even video dimensions always; crop (never scale) one row/column when odd.
- Every error reaches the user as an `NSAlert`; nothing is swallowed. Use `os.Logger(subsystem: "com.barsmike.RecRec", category: ...)` for logs.
- Run tests with `make test` (= `swift run RecRecTests`). Commit after every task.

## File structure

```
Package.swift                              three targets
Makefile                                   build / test / app / run / bench / clean
Packaging/Info.plist                       bundle metadata (LSUIElement, mic usage string)
Sources/RecRecCore/
  RecordingSettings.swift                  enums + settings struct + defaults
  SettingsStore.swift                      UserDefaults persistence
  EncoderConfig.swift                      quality table, video/audio settings, capture geometry
  FrameGate.swift                          VFR decision logic
  RecordingWriter.swift                    AVAssetWriter wrapper (video, audio, heartbeat, finish)
  OutputNaming.swift                       file names, collision handling
  DiskSpace.swift                          free space check
  GIFExporter.swift                        MP4 → GIF
  RecRecError.swift                        core error type
Sources/RecRec/
  main.swift                               NSApplication bootstrap
  AppDelegate.swift                        wiring, termination while recording
  StatusMenuController.swift               status item + menu + alerts
  ScreenRecorder.swift                     SCStream orchestration (state machine)
  StreamOutputRelay.swift                  non-isolated SCStreamOutput/SCStreamDelegate → writer
  MicrophoneCapture.swift                  AVCaptureSession audio → writer
  DisplaySelection.swift                   which display, pixel sizes
  HotKey.swift                             Carbon global hotkey
  Permissions.swift                        alerts + "Open System Settings"
  LaunchAtLogin.swift                      SMAppService wrapper
Sources/RecRecTests/
  TestHarness.swift                        runner + expect helpers
  TestMain.swift                           registers suites, exit code
  SyntheticMedia.swift                     pixel buffers + audio sample buffers for tests
  RecordingSettingsTests.swift
  EncoderConfigTests.swift
  FrameGateTests.swift
  OutputNamingTests.swift
  RecordingWriterTests.swift
  GIFExporterTests.swift
README.md
```

---

### Task 1: Package skeleton, test harness, Makefile

**Files:**
- Create: `Package.swift`, `Makefile`, `Packaging/Info.plist`
- Create: `Sources/RecRecCore/RecRecError.swift`
- Create: `Sources/RecRec/main.swift` (placeholder, replaced in Task 8)
- Create: `Sources/RecRecTests/TestHarness.swift`, `Sources/RecRecTests/TestMain.swift`

**Interfaces:**
- Produces: `TestRunner.test(_ name: String, _ body: @escaping () async throws -> Void)`, `expect(_:_:file:line:)`, `expectEqual(_:_:_:file:line:)`, `expectNear(_:_:tolerance:_:file:line:)`, `expectThrows(_:_:file:line:)`; `RecRecError` enum.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecRec",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RecRecCore", path: "Sources/RecRecCore"),
        .executableTarget(name: "RecRec", dependencies: ["RecRecCore"], path: "Sources/RecRec"),
        .executableTarget(name: "RecRecTests", dependencies: ["RecRecCore"], path: "Sources/RecRecTests"),
    ]
)
```

- [ ] **Step 2: Write the core error type**

`Sources/RecRecCore/RecRecError.swift`:

```swift
import Foundation

public enum RecRecError: LocalizedError, Equatable {
    case insufficientDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    case writerSetupFailed(String)
    case writerFailed(String)
    case noVideoFrames
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(available, required):
            let f = ByteCountFormatter()
            return "Not enough free disk space: \(f.string(fromByteCount: available)) available, \(f.string(fromByteCount: required)) required."
        case let .writerSetupFailed(reason): return "Could not create the recording file: \(reason)"
        case let .writerFailed(reason): return "Recording failed while writing: \(reason)"
        case .noVideoFrames: return "No video frames were captured."
        case let .exportFailed(reason): return "Export failed: \(reason)"
        }
    }
}
```

- [ ] **Step 3: Write the test harness**

`Sources/RecRecTests/TestHarness.swift`:

```swift
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: UInt
    var description: String { "\(file):\(line): \(message)" }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expected condition to be true",
            file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw TestFailure(message: message, file: "\(file)", line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) throws {
    if actual != expected {
        throw TestFailure(message: "expected \(expected), got \(actual). \(message)", file: "\(file)", line: line)
    }
}

func expectNear(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) throws {
    if abs(actual - expected) > tolerance {
        throw TestFailure(message: "expected \(expected) ± \(tolerance), got \(actual). \(message)", file: "\(file)", line: line)
    }
}

func expectThrows(_ body: () async throws -> Void, _ message: String = "expected an error",
                  file: StaticString = #filePath, line: UInt = #line) async throws {
    do { try await body() } catch { return }
    throw TestFailure(message: message, file: "\(file)", line: line)
}

final class TestRunner {
    private var tests: [(name: String, body: () async throws -> Void)] = []

    func test(_ name: String, _ body: @escaping () async throws -> Void) {
        tests.append((name, body))
    }

    /// Runs every test; returns the number of failures.
    func run() async -> Int {
        var failures = 0
        let filter = ProcessInfo.processInfo.environment["TEST_FILTER"]
        for t in tests where filter == nil || t.name.contains(filter!) {
            let start = Date()
            do {
                try await t.body()
                print("PASS  \(t.name) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
            } catch {
                failures += 1
                print("FAIL  \(t.name)\n      \(error)")
            }
        }
        print("\n\(tests.count - failures) passed, \(failures) failed")
        return failures
    }
}
```

`Sources/RecRecTests/TestMain.swift`:

```swift
import Foundation

@main
struct TestMain {
    static func main() async {
        let runner = TestRunner()
        runner.test("harness smoke") { try expectEqual(1 + 1, 2) }
        let failures = await runner.run()
        exit(failures == 0 ? 0 : 1)
    }
}
```

- [ ] **Step 4: Placeholder app main and Info.plist**

`Sources/RecRec/main.swift`:

```swift
import AppKit
print("RecRec placeholder")
```

`Packaging/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>RecRec</string>
    <key>CFBundleIdentifier</key><string>com.barsmike.RecRec</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>RecRec</string>
    <key>CFBundleDisplayName</key><string>RecRec</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RecRec records your microphone only while the Microphone option is on.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
```

- [ ] **Step 5: Makefile**

```make
APP        := RecRec
BUNDLE_ID  := com.barsmike.RecRec
VERSION    ?= 0.1.0
SIGN       ?= -
DIST       := dist/$(APP).app
ifeq ($(UNIVERSAL),1)
  ARCHS    := --arch arm64 --arch x86_64
  BUILD    := .build/apple/Products/Release
else
  ARCHS    :=
  BUILD    := .build/release
endif

.PHONY: build test app run bench clean

build:
	swift build -c release $(ARCHS)

test:
	swift run RecRecTests

app: build
	rm -rf "$(DIST)"
	mkdir -p "$(DIST)/Contents/MacOS" "$(DIST)/Contents/Resources"
	cp "$(BUILD)/$(APP)" "$(DIST)/Contents/MacOS/$(APP)"
	sed -e 's/__VERSION__/$(VERSION)/g' Packaging/Info.plist > "$(DIST)/Contents/Info.plist"
	printf 'APPL????' > "$(DIST)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN)" --identifier $(BUNDLE_ID) "$(DIST)"
	@echo "Built $(DIST)"; du -sh "$(DIST)"; ls -l "$(DIST)/Contents/MacOS/$(APP)" | awk '{print "binary:", $$5, "bytes"}'

run: app
	open "$(DIST)"

bench:
	mkdir -p .build/bench && swiftc -O -o .build/bench/encbench tools/encbench/encbench.swift
	.build/bench/encbench --scale 2 --seconds 60 --set core --outdir .build/bench/out --ref 5,15,45
	tools/encbench/quality.sh .build/bench/out 3456x2234

clean:
	rm -rf .build dist
```

- [ ] **Step 6: Build and run the harness**

Run: `swift build && make test`
Expected: `PASS  harness smoke` and `1 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Makefile Packaging Sources && git commit -m "Scaffold SwiftPM package, test harness and app bundle Makefile"
```

---

### Task 2: RecordingSettings and SettingsStore

**Files:**
- Create: `Sources/RecRecCore/RecordingSettings.swift`, `Sources/RecRecCore/SettingsStore.swift`
- Test: `Sources/RecRecTests/RecordingSettingsTests.swift`; modify `TestMain.swift` to register `registerRecordingSettingsTests(runner)`.

**Interfaces:**
- Produces: `VideoCodec {h264, hevc}`, `Container {mp4, mov}` (+ `fileExtension`), `QualityTier {small, balanced, high}`, `ResolutionScale {retina, standard}`, `struct RecordingSettings` (fields below, `static let defaults`), `SettingsStore(defaults: UserDefaults)` with `load() -> RecordingSettings` and `save(_:)`.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import RecRecCore

func registerRecordingSettingsTests(_ r: TestRunner) {
    r.test("settings defaults match the spec") {
        let s = RecordingSettings.defaults
        try expectEqual(s.microphoneEnabled, false)
        try expectEqual(s.systemAudioEnabled, false)
        try expectEqual(s.showsCursor, true)
        try expectEqual(s.quality, .balanced)
        try expectEqual(s.codec, .hevc)
        try expectEqual(s.container, .mp4)
        try expectEqual(s.frameRate, 30)
        try expectEqual(s.resolution, .retina)
        try expectEqual(s.revealInFinder, true)
        try expectEqual(s.pinnedDisplayID, nil)
        try expectEqual(s.saveDirectory.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/RecRec").path)
    }
    r.test("settings round-trip through JSON") {
        var s = RecordingSettings.defaults
        s.codec = .h264; s.container = .mov; s.frameRate = 60; s.pinnedDisplayID = 42
        s.saveDirectory = URL(fileURLWithPath: "/tmp/recs")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(RecordingSettings.self, from: data)
        try expectEqual(back, s)
    }
    r.test("store saves and loads, and falls back to defaults on garbage") {
        let defaults = UserDefaults(suiteName: "com.barsmike.RecRec.tests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        try expectEqual(store.load(), RecordingSettings.defaults)
        var s = RecordingSettings.defaults; s.quality = .high; s.microphoneEnabled = true
        store.save(s)
        try expectEqual(store.load(), s)
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        try expectEqual(store.load(), RecordingSettings.defaults)
    }
    r.test("container file extensions") {
        try expectEqual(Container.mp4.fileExtension, "mp4")
        try expectEqual(Container.mov.fileExtension, "mov")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: compile error (types missing).

- [ ] **Step 3: Implement**

`Sources/RecRecCore/RecordingSettings.swift`:

```swift
import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Equatable { case h264, hevc }

public enum Container: String, Codable, CaseIterable, Equatable {
    case mp4, mov
    public var fileExtension: String { rawValue }
}

public enum QualityTier: String, Codable, CaseIterable, Equatable { case small, balanced, high }

public enum ResolutionScale: String, Codable, CaseIterable, Equatable { case retina, standard }

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
    public var pinnedDisplayID: UInt32?
    public var saveDirectory: URL

    public static let frameRateChoices = [15, 24, 30, 60]

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
        saveDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/RecRec", isDirectory: true)
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
```

`Sources/RecRecCore/SettingsStore.swift`:

```swift
import Foundation

public final class SettingsStore {
    public static let key = "recordingSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: RecordingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
```

Register in `TestMain.swift`: `registerRecordingSettingsTests(runner)` before `runner.run()`.

- [ ] **Step 4: Run tests**

Run: `make test` — Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add RecordingSettings model and UserDefaults store"
```

---

### Task 3: EncoderConfig (quality table, writer settings, capture geometry)

**Files:**
- Create: `Sources/RecRecCore/EncoderConfig.swift`
- Test: `Sources/RecRecTests/EncoderConfigTests.swift`; register `registerEncoderConfigTests(runner)`.

**Interfaces:**
- Produces:
  - `EncoderConfig.qualityValue(codec: VideoCodec, tier: QualityTier, scale: ResolutionScale) -> Double`
  - `EncoderConfig.videoSettings(codec:tier:scale:width:height:frameRate:) -> [String: Any]`
  - `AudioTrackKind {microphone, system}`; `EncoderConfig.audioSettings(kind: AudioTrackKind) -> [String: Any]`
  - `struct CaptureGeometry { width: Int; height: Int; sourceRect: CGRect; usesNominalResolution: Bool }`
  - `EncoderConfig.captureGeometry(pointSize: CGSize, pixelSize: CGSize, scale: ResolutionScale) -> CaptureGeometry`
  - constants `EncoderConfig.keyframeIntervalSeconds = 10.0`, `heartbeatIntervalSeconds = 2.0`, `fragmentIntervalSeconds = 5.0`

- [ ] **Step 1: Write failing tests**

```swift
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
        let retina = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1728, height: 1117), pixelSize: CGSize(width: 3456, height: 2234), scale: .retina)
        try expectEqual(retina.width, 3456); try expectEqual(retina.height, 2234)
        try expectEqual(retina.sourceRect, CGRect(x: 0, y: 0, width: 1728, height: 1117))
        try expectEqual(retina.usesNominalResolution, false)
        let standard = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1728, height: 1117), pixelSize: CGSize(width: 3456, height: 2234), scale: .standard)
        try expectEqual(standard.width, 1728); try expectEqual(standard.height, 1116)
        try expectEqual(standard.sourceRect, CGRect(x: 0, y: 0, width: 1728, height: 1116))
        try expectEqual(standard.usesNominalResolution, true)
        let oddRetina = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1281, height: 801), pixelSize: CGSize(width: 2562, height: 1602), scale: .retina)
        try expectEqual(oddRetina.width, 2562); try expectEqual(oddRetina.height, 1602)
        let nonRetina = EncoderConfig.captureGeometry(pointSize: CGSize(width: 1919, height: 1080), pixelSize: CGSize(width: 1919, height: 1080), scale: .retina)
        try expectEqual(nonRetina.width, 1918); try expectEqual(nonRetina.height, 1080)
        try expectEqual(nonRetina.sourceRect, CGRect(x: 0, y: 0, width: 1918, height: 1080))
    }
    r.test("capture geometry: h264 5K display is downscaled to fit 4096x2304, hevc is not") {
        let fiveK = EncoderConfig.captureGeometry(pointSize: CGSize(width: 2560, height: 1440), pixelSize: CGSize(width: 5120, height: 2880), scale: .retina, codec: .h264)
        try expectEqual(fiveK.width, 4096); try expectEqual(fiveK.height, 2304)
        try expectEqual(fiveK.sourceRect, CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let hevc = EncoderConfig.captureGeometry(pointSize: CGSize(width: 2560, height: 1440), pixelSize: CGSize(width: 5120, height: 2880), scale: .retina, codec: .hevc)
        try expectEqual(hevc.width, 5120); try expectEqual(hevc.height, 2880)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make test` → compile error.

- [ ] **Step 3: Implement**

`Sources/RecRecCore/EncoderConfig.swift`:

```swift
import Foundation
import AVFoundation
import VideoToolbox

public enum AudioTrackKind: String, Equatable { case microphone, system }

public struct CaptureGeometry: Equatable {
    public var width: Int
    public var height: Int
    /// In display points; the region of the display that maps 1:1 (or 1:scale) onto width×height.
    public var sourceRect: CGRect
    public var usesNominalResolution: Bool
}

public enum EncoderConfig {
    public static let keyframeIntervalSeconds: Double = 10
    public static let heartbeatIntervalSeconds: Double = 2
    public static let fragmentIntervalSeconds: Double = 5
    public static let audioSampleRate: Double = 48_000

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

    public static func audioSettings(kind: AudioTrackKind) -> [String: Any] {
        let channels = kind == .microphone ? 1 : 2
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: kind == .microphone ? 64_000 : 128_000,
        ]
    }

    public static func captureGeometry(pointSize: CGSize, pixelSize: CGSize, scale: ResolutionScale) -> CaptureGeometry {
        let factor = pointSize.width > 0 ? pixelSize.width / pointSize.width : 1
        switch scale {
        case .retina:
            let w = Int(pixelSize.width) & ~1, h = Int(pixelSize.height) & ~1
            return CaptureGeometry(width: w, height: h,
                                   sourceRect: CGRect(x: 0, y: 0, width: Double(w) / factor, height: Double(h) / factor),
                                   usesNominalResolution: false)
        case .standard:
            let w = Int(pointSize.width) & ~1, h = Int(pointSize.height) & ~1
            return CaptureGeometry(width: w, height: h,
                                   sourceRect: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)),
                                   usesNominalResolution: true)
        }
    }
}
```

- [ ] **Step 4: Run tests** — `make test` → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add EncoderConfig: quality table, writer settings, capture geometry"`

---

### Task 4: FrameGate

**Files:**
- Create: `Sources/RecRecCore/FrameGate.swift`
- Test: `Sources/RecRecTests/FrameGateTests.swift`; register `registerFrameGateTests(runner)`.

**Interfaces:**
- Produces: `enum FrameStatus { complete, idle, other }`, `struct FrameGate` with `init(heartbeatInterval: CMTime)`, `mutating func decide(status: FrameStatus, presentationTime: CMTime) -> Bool` (true = append; also records the append), `func heartbeatDue(now: CMTime) -> Bool`, `mutating func noteAppended(at: CMTime)`, `var lastAppended: CMTime`, `var hasStarted: Bool`.

- [ ] **Step 1: Write failing tests**

```swift
import CoreMedia
import RecRecCore

func registerFrameGateTests(_ r: TestRunner) {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    r.test("first frame must be complete; idle and other frames are skipped before start") {
        var g = FrameGate(heartbeatInterval: t(2))
        try expectEqual(g.decide(status: .idle, presentationTime: t(0)), false)
        try expectEqual(g.decide(status: .other, presentationTime: t(0.1)), false)
        try expectEqual(g.hasStarted, false)
        try expectEqual(g.decide(status: .complete, presentationTime: t(0.2)), true)
        try expectEqual(g.hasStarted, true)
        try expectEqual(g.lastAppended, t(0.2))
    }
    r.test("complete frames append, idle frames skip, non-increasing timestamps skip") {
        var g = FrameGate(heartbeatInterval: t(2))
        _ = g.decide(status: .complete, presentationTime: t(1))
        try expectEqual(g.decide(status: .idle, presentationTime: t(1.1)), false)
        try expectEqual(g.decide(status: .complete, presentationTime: t(1)), false, "same pts")
        try expectEqual(g.decide(status: .complete, presentationTime: t(0.5)), false, "earlier pts")
        try expectEqual(g.decide(status: .complete, presentationTime: t(1.2)), true)
        try expectEqual(g.lastAppended, t(1.2))
    }
    r.test("heartbeat is due only after the interval, and only after start") {
        var g = FrameGate(heartbeatInterval: t(2))
        try expectEqual(g.heartbeatDue(now: t(10)), false)
        _ = g.decide(status: .complete, presentationTime: t(1))
        try expectEqual(g.heartbeatDue(now: t(2.5)), false)
        try expectEqual(g.heartbeatDue(now: t(3)), true)
        g.noteAppended(at: t(3))
        try expectEqual(g.heartbeatDue(now: t(4)), false)
        try expectEqual(g.lastAppended, t(3))
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

```swift
import CoreMedia

public enum FrameStatus: Equatable { case complete, idle, other }

/// Decides which captured frames are written. Only complete frames with increasing timestamps are
/// appended; idle frames (unchanged screen) are skipped and a heartbeat re-appends the last frame
/// when nothing was written for `heartbeatInterval`.
public struct FrameGate {
    public let heartbeatInterval: CMTime
    public private(set) var lastAppended: CMTime = .invalid

    public init(heartbeatInterval: CMTime) { self.heartbeatInterval = heartbeatInterval }

    public var hasStarted: Bool { lastAppended.isValid }

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

    public mutating func noteAppended(at time: CMTime) { lastAppended = time }
}
```

- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add FrameGate for variable-frame-rate decisions"`

---

### Task 5: OutputNaming and DiskSpace

**Files:**
- Create: `Sources/RecRecCore/OutputNaming.swift`, `Sources/RecRecCore/DiskSpace.swift`
- Test: `Sources/RecRecTests/OutputNamingTests.swift`; register `registerOutputNamingTests(runner)`.

**Interfaces:**
- Produces: `OutputNaming.fileName(date: Date, container: Container) -> String`, `OutputNaming.uniqueURL(in directory: URL, container: Container, date: Date, fileManager: FileManager = .default) -> URL`, `OutputNaming.gifURL(for videoURL: URL, fileManager:) -> URL`; `DiskSpace.freeBytes(at: URL) throws -> Int64`, `DiskSpace.ensureFreeSpace(at: URL, minimumBytes: Int64) throws` (throws `RecRecError.insufficientDiskSpace`), `DiskSpace.minimumBytesToStart = 500_000_000`.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import RecRecCore

func registerOutputNamingTests(_ r: TestRunner) {
    r.test("file name is sortable 24-hour local time") {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 7; c.hour = 22; c.minute = 41; c.second = 5
        let date = Calendar.current.date(from: c)!
        try expectEqual(OutputNaming.fileName(date: date, container: .mp4), "Recording 2026-09-07 at 22.41.05.mp4")
        try expectEqual(OutputNaming.fileName(date: date, container: .mov), "Recording 2026-09-07 at 22.41.05.mov")
    }
    r.test("unique URL adds a counter on collision") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recrec-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let date = Date()
        let first = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expectEqual(first.lastPathComponent, OutputNaming.fileName(date: date, container: .mp4))
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expect(second.lastPathComponent.hasSuffix(" 2.mp4"), "got \(second.lastPathComponent)")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = OutputNaming.uniqueURL(in: dir, container: .mp4, date: date)
        try expect(third.lastPathComponent.hasSuffix(" 3.mp4"), "got \(third.lastPathComponent)")
        let gif = OutputNaming.gifURL(for: first)
        try expectEqual(gif.pathExtension, "gif")
        try expectEqual(gif.deletingPathExtension().lastPathComponent, first.deletingPathExtension().lastPathComponent)
    }
    r.test("disk space is positive for the temp dir and the guard throws for absurd minimums") {
        let tmp = FileManager.default.temporaryDirectory
        try expect(try DiskSpace.freeBytes(at: tmp) > 0)
        try DiskSpace.ensureFreeSpace(at: tmp, minimumBytes: 1)
        try await expectThrows { try DiskSpace.ensureFreeSpace(at: tmp, minimumBytes: Int64.max) }
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

`OutputNaming.swift`:

```swift
import Foundation

public enum OutputNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    public static func baseName(date: Date) -> String { "Recording \(formatter.string(from: date))" }

    public static func fileName(date: Date, container: Container) -> String {
        "\(baseName(date: date)).\(container.fileExtension)"
    }

    public static func uniqueURL(in directory: URL, container: Container, date: Date,
                                 fileManager: FileManager = .default) -> URL {
        uniqueURL(in: directory, baseName: baseName(date: date), pathExtension: container.fileExtension, fileManager: fileManager)
    }

    public static func gifURL(for videoURL: URL, fileManager: FileManager = .default) -> URL {
        uniqueURL(in: videoURL.deletingLastPathComponent(),
                  baseName: videoURL.deletingPathExtension().lastPathComponent,
                  pathExtension: "gif", fileManager: fileManager)
    }

    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String, fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(pathExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter).\(pathExtension)")
            counter += 1
        }
        return candidate
    }
}
```

`DiskSpace.swift`:

```swift
import Foundation

public enum DiskSpace {
    public static let minimumBytesToStart: Int64 = 500_000_000

    public static func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public static func ensureFreeSpace(at url: URL, minimumBytes: Int64 = minimumBytesToStart) throws {
        let free = try freeBytes(at: url)
        if free < minimumBytes {
            throw RecRecError.insufficientDiskSpace(availableBytes: free, requiredBytes: minimumBytes)
        }
    }
}
```

- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add output naming and disk space checks"`

---

### Task 6: RecordingWriter (AVAssetWriter wrapper) with synthetic-media tests

**Files:**
- Create: `Sources/RecRecCore/RecordingWriter.swift`
- Create: `Sources/RecRecTests/SyntheticMedia.swift`, `Sources/RecRecTests/RecordingWriterTests.swift`; register `registerRecordingWriterTests(runner)`.

**Interfaces:**
- Consumes: `FrameGate`, `FrameStatus`, `Container`, `AudioTrackKind`, `EncoderConfig` constants, `RecRecError`.
- Produces:
  ```swift
  public struct AudioTrackSpec { public var kind: AudioTrackKind; public var settings: [String: Any] }
  public struct WriterConfiguration {
      public var outputURL: URL; public var container: Container; public var videoSettings: [String: Any]
      public var audioTracks: [AudioTrackSpec]; public var clock: CMClock
      public var heartbeatInterval: Double; public var fragmentInterval: Double
      public init(outputURL:container:videoSettings:audioTracks:clock:heartbeatInterval:fragmentInterval:)
  }
  public struct RecordingResult: Equatable { public var url: URL; public var duration: Double; public var fileSize: Int64; public var videoFrames: Int }
  public final class RecordingWriter {
      public let configuration: WriterConfiguration
      public var onError: ((Error) -> Void)?
      public init(configuration: WriterConfiguration) throws
      public func appendVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, status: FrameStatus)
      public func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind)
      public func heartbeat(now: CMTime)          // also called by the internal timer
      public func finish(at endTime: CMTime) async throws -> RecordingResult
  }
  ```

- [ ] **Step 1: Write the synthetic media helpers**

`Sources/RecRecTests/SyntheticMedia.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

enum SyntheticMedia {
    /// A 4:2:0 video-range pixel buffer whose luma pattern depends on `frame` (so frames differ).
    static func pixelBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for col in 0..<width {
                let stripe = ((col / 64) + frame) % 2 == 0
                y[row * yStride + col] = stripe ? 200 : 40
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Mono Float32 PCM sample buffer with a 440 Hz tone.
    static func audioSampleBuffer(startTime: CMTime, frames: Int, sampleRate: Double = 48_000) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferAssureBlockMemory(block!)
        var samples = [Float](repeating: 0, count: frames)
        let startFrame = CMTimeGetSeconds(startTime) * sampleRate
        for i in 0..<frames { samples[i] = 0.2 * sinf(Float(2 * Double.pi * 440 * (startFrame + Double(i)) / sampleRate)) }
        samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: startTime, decodeTimeStamp: .invalid)
        var sizes = [4]
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb)
        return sb!
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recrec-test-\(UUID().uuidString).\(ext)")
    }

    struct AssetInfo { var duration: Double; var videoFrames: Int; var hasAudio: Bool; var codec: String; var width: Int; var height: Int }

    static func inspect(_ url: URL) async throws -> AssetInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first!
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video.load(.naturalSize)
        let desc = try await video.load(.formatDescriptions).first!
        let codec = String(describing: CMFormatDescriptionGetMediaSubType(desc).fourCharString)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output); reader.startReading()
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        return AssetInfo(duration: CMTimeGetSeconds(duration), videoFrames: frames, hasAudio: !audio.isEmpty, codec: codec, width: Int(size.width), height: Int(size.height))
    }

    static func countAtoms(_ url: URL, _ atom: String) throws -> Int {
        let data = try Data(contentsOf: url)
        let needle = Data(atom.utf8)
        var count = 0, range = data.startIndex..<data.endIndex
        while let r = data.range(of: needle, in: range) { count += 1; range = r.upperBound..<data.endIndex }
        return count
    }
}

extension FourCharCode {
    var fourCharString: String {
        let bytes = [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
```

- [ ] **Step 2: Write failing writer tests**

`Sources/RecRecTests/RecordingWriterTests.swift`:

```swift
import Foundation
import AVFoundation
import RecRecCore

func registerRecordingWriterTests(_ r: TestRunner) {
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    func config(_ url: URL, codec: VideoCodec = .hevc, container: Container = .mp4, audio: [AudioTrackKind] = [],
                fragment: Double = EncoderConfig.fragmentIntervalSeconds) -> WriterConfiguration {
        WriterConfiguration(
            outputURL: url, container: container,
            videoSettings: EncoderConfig.videoSettings(codec: codec, tier: .balanced, scale: .standard, width: 640, height: 360, frameRate: 30),
            audioTracks: audio.map { AudioTrackSpec(kind: $0, settings: EncoderConfig.audioSettings(kind: $0)) },
            clock: CMClockGetHostTimeClock(), heartbeatInterval: EncoderConfig.heartbeatIntervalSeconds, fragmentInterval: fragment)
    }

    r.test("writer produces a playable HEVC mp4 with the session duration and a final frame") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url))
        for i in 0..<90 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete) }
        let result = try await w.finish(at: t(3))
        let info = try await SyntheticMedia.inspect(url)
        try expectNear(info.duration, 3.0, tolerance: 0.05)
        try expectEqual(info.videoFrames, 91, "90 frames + final frame at 3 s")
        try expectEqual(result.videoFrames, 91)
        try expectEqual(info.codec, "hvc1")
        try expectEqual(info.width, 640); try expectEqual(info.height, 360)
        try expect(result.fileSize > 1000)
        try expectEqual(result.url, url)
        try expectNear(result.duration, 3.0, tolerance: 0.01)
    }

    r.test("idle frames are skipped, heartbeat re-appends, idle tail keeps the duration") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url))
        for i in 0..<30 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete) }
        for i in 30..<150 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: 29), presentationTime: t(Double(i) / 30), status: .idle) }
        w.heartbeat(now: t(1.5))   // not due (last frame at 0.967 s)
        w.heartbeat(now: t(3.0))   // due → re-append at 3.0
        let result = try await w.finish(at: t(5))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.videoFrames, 32, "30 complete + 1 heartbeat + 1 final")
        try expectNear(info.duration, 5.0, tolerance: 0.05)
        try expectNear(result.duration, 5.0, tolerance: 0.01)
    }

    r.test("session starts at the first complete frame; earlier idle frames are ignored") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url))
        w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: 0), presentationTime: t(10), status: .idle)
        for i in 0..<30 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(11 + Double(i) / 30), status: .complete) }
        let result = try await w.finish(at: t(12))
        try expectNear(result.duration, 1.0, tolerance: 0.01)
        let info = try await SyntheticMedia.inspect(url)
        try expectNear(info.duration, 1.0, tolerance: 0.05)
    }

    r.test("h264 mov output with fragments is readable, and moof atoms exist") {
        let url = SyntheticMedia.tempURL("mov")
        let w = try RecordingWriter(configuration: config(url, codec: .h264, container: .mov, fragment: 1))
        for i in 0..<120 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete) }
        _ = try await w.finish(at: t(4))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.codec, "avc1")
        try expectNear(info.duration, 4.0, tolerance: 0.05)
        try expect(try SyntheticMedia.countAtoms(url, "moof") >= 2, "expected movie fragments")
    }

    r.test("a file left unfinished is still readable thanks to fragments") {
        let url = SyntheticMedia.tempURL("mp4")
        do {
            let w = try RecordingWriter(configuration: config(url, fragment: 1))
            for i in 0..<180 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete) }
            try await w.abandonForTesting()
        }
        let info = try await SyntheticMedia.inspect(url)
        try expect(info.duration >= 3.0, "recovered \(info.duration)s of 6s")
    }

    r.test("microphone audio is written as a track, including a buffer that starts before the session") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url, audio: [.microphone]))
        w.appendAudio(SyntheticMedia.audioSampleBuffer(startTime: t(-0.1), frames: 4800), kind: .microphone)  // dropped: before session
        for i in 0..<60 {
            w.appendVideo(SyntheticMedia.pixelBuffer(width: 640, height: 360, frame: i), presentationTime: t(Double(i) / 30), status: .complete)
            if i % 3 == 0 { w.appendAudio(SyntheticMedia.audioSampleBuffer(startTime: t(Double(i) / 30), frames: 4800), kind: .microphone) }
        }
        let result = try await w.finish(at: t(2))
        let info = try await SyntheticMedia.inspect(url)
        try expectEqual(info.hasAudio, true)
        try expectNear(info.duration, 2.0, tolerance: 0.1)
        try expect(result.fileSize > 0)
    }

    r.test("finishing with no frames throws noVideoFrames and removes the file") {
        let url = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: config(url))
        try await expectThrows { _ = try await w.finish(at: t(1)) }
        try expectEqual(FileManager.default.fileExists(atPath: url.path), false)
    }
}
```

- [ ] **Step 3: Run to verify failure** — compile error.

- [ ] **Step 4: Implement the writer**

`Sources/RecRecCore/RecordingWriter.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia
import os

public struct AudioTrackSpec {
    public var kind: AudioTrackKind
    public var settings: [String: Any]
    public init(kind: AudioTrackKind, settings: [String: Any]) { self.kind = kind; self.settings = settings }
}

public struct WriterConfiguration {
    public var outputURL: URL
    public var container: Container
    public var videoSettings: [String: Any]
    public var audioTracks: [AudioTrackSpec]
    public var clock: CMClock
    public var heartbeatInterval: Double
    public var fragmentInterval: Double

    public init(outputURL: URL, container: Container, videoSettings: [String: Any], audioTracks: [AudioTrackSpec],
                clock: CMClock, heartbeatInterval: Double = EncoderConfig.heartbeatIntervalSeconds,
                fragmentInterval: Double = EncoderConfig.fragmentIntervalSeconds) {
        self.outputURL = outputURL; self.container = container; self.videoSettings = videoSettings
        self.audioTracks = audioTracks; self.clock = clock
        self.heartbeatInterval = heartbeatInterval; self.fragmentInterval = fragmentInterval
    }
}

public struct RecordingResult: Equatable {
    public var url: URL
    public var duration: Double
    public var fileSize: Int64
    public var videoFrames: Int
}

/// Wraps AVAssetWriter for a live capture: video through a pixel-buffer adaptor with idle-frame
/// skipping and heartbeats, optional AAC audio tracks, movie fragments for crash safety.
/// Thread-safe: every call is serialized on an internal queue.
public final class RecordingWriter {
    public let configuration: WriterConfiguration
    /// Called (on the writer queue) the first time the underlying writer fails.
    public var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.barsmike.RecRec.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
    private var gate: FrameGate
    private var sessionStart: CMTime = .invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private var videoFrames = 0
    private var droppedFrames = 0
    private var reportedError = false
    private var finished = false
    private var timer: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "writer")

    public init(configuration: WriterConfiguration) throws {
        self.configuration = configuration
        let fileType: AVFileType = configuration.container == .mov ? .mov : .mp4
        do {
            writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: fileType)
        } catch {
            throw RecRecError.writerSetupFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = false
        if configuration.fragmentInterval > 0 {
            writer.movieFragmentInterval = CMTime(seconds: configuration.fragmentInterval, preferredTimescale: 600)
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: configuration.videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw RecRecError.writerSetupFailed("video settings rejected") }
        writer.add(videoInput)
        for track in configuration.audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: track.settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecRecError.writerSetupFailed("audio settings rejected") }
            writer.add(input)
            audioInputs[track.kind] = input
        }
        gate = FrameGate(heartbeatInterval: CMTime(seconds: configuration.heartbeatInterval, preferredTimescale: 600))
        guard writer.startWriting() else {
            throw RecRecError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        startHeartbeatTimer()
    }

    // MARK: - Appending

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, status: FrameStatus) {
        queue.async { [self] in
            guard !finished, gate.decide(status: status, presentationTime: presentationTime) else { return }
            if !sessionStart.isValid {
                sessionStart = presentationTime
                writer.startSession(atSourceTime: presentationTime)
            }
            append(pixelBuffer, at: presentationTime)
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind) {
        queue.async { [self] in
            guard !finished, sessionStart.isValid, let input = audioInputs[kind] else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sampleBuffer))
            guard CMTimeCompare(end, sessionStart) > 0 else { return }
            guard input.isReadyForMoreMediaData else { return }
            if !input.append(sampleBuffer) { reportFailure() }
        }
    }

    /// Re-appends the last frame when nothing was written for the heartbeat interval.
    public func heartbeat(now: CMTime) {
        queue.async { [self] in
            guard !finished, gate.heartbeatDue(now: now), let last = lastPixelBuffer else { return }
            gate.noteAppended(at: now)
            append(last, at: now)
        }
    }

    // MARK: - Finishing

    public func finish(at endTime: CMTime) async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingResult, Error>) in
            queue.async { [self] in
                timer?.cancel(); timer = nil
                guard !finished else { continuation.resume(throwing: RecRecError.writerFailed("already finished")); return }
                finished = true
                guard sessionStart.isValid else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: configuration.outputURL)
                    continuation.resume(throwing: RecRecError.noVideoFrames)
                    return
                }
                if writer.status == .writing, let last = lastPixelBuffer, CMTimeCompare(endTime, gate.lastAppended) > 0 {
                    gate.noteAppended(at: endTime)
                    append(last, at: endTime)
                }
                if writer.status == .failed {
                    continuation.resume(throwing: RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    return
                }
                videoInput.markAsFinished()
                audioInputs.values.forEach { $0.markAsFinished() }
                writer.endSession(atSourceTime: endTime)
                let duration = CMTimeGetSeconds(CMTimeSubtract(endTime, sessionStart))
                let frames = videoFrames
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        let size = (try? FileManager.default.attributesOfItem(atPath: configuration.outputURL.path)[.size] as? Int64) ?? 0
                        log.info("finished \(self.configuration.outputURL.lastPathComponent, privacy: .public): \(frames) frames, \(self.droppedFrames) dropped, \(size) bytes")
                        continuation.resume(returning: RecordingResult(url: configuration.outputURL, duration: duration, fileSize: size, videoFrames: frames))
                    } else {
                        continuation.resume(throwing: RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown"))
                    }
                }
            }
        }
    }

    /// Test hook: stops the timer and drops the writer without finalizing, simulating a crash.
    public func abandonForTesting() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in timer?.cancel(); timer = nil; finished = true; c.resume() }
        }
    }

    // MARK: - Private

    private func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing else { reportFailure(); return }
        guard videoInput.isReadyForMoreMediaData else { droppedFrames += 1; return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastPixelBuffer = pixelBuffer
            videoFrames += 1
        } else {
            reportFailure()
        }
    }

    private func reportFailure() {
        guard !reportedError, writer.status == .failed else { return }
        reportedError = true
        let error = RecRecError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        log.error("writer failed: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    private func startHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = max(0.25, configuration.heartbeatInterval / 2)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CMClockGetTime(self.configuration.clock)
            guard !self.finished, self.gate.heartbeatDue(now: now), let last = self.lastPixelBuffer else { return }
            self.gate.noteAppended(at: now)
            self.append(last, at: now)
        }
        timer.resume()
        self.timer = timer
    }
}
```

Note for the implementer: the internal timer only matters in the app, where frame timestamps come from the same clock as `configuration.clock`. In tests, timestamps are synthetic (0…5 s) while the host clock is huge, so the timer's `heartbeatDue(now:)` would be true after the first frame. To keep tests deterministic, tests pass `heartbeatInterval` as above but the timer must not fire in tests: add `public var automaticHeartbeat: Bool` to `WriterConfiguration` (default `true`) and only call `startHeartbeatTimer()` when it is true; the test `config(...)` helper sets it to `false`. Add the field to the initializer with a default value.

- [ ] **Step 5: Run tests** — `make test` → all PASS. If `hvc1`/`avc1` differ (e.g. `hev1`), print the actual value and adjust the expectation only if the file still plays with `ffprobe`.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "Add RecordingWriter with VFR, heartbeat, audio tracks and fragments"`

---

### Task 7: GIFExporter

**Files:**
- Create: `Sources/RecRecCore/GIFExporter.swift`
- Test: `Sources/RecRecTests/GIFExporterTests.swift`; register `registerGIFExporterTests(runner)`.

**Interfaces:**
- Produces: `struct GIFExportOptions { framesPerSecond: Int = 10; maxWidth: Int = 1200 }`, `GIFExporter.export(video: URL, to: URL, options: GIFExportOptions, progress: ((Double) -> Void)?) async throws -> Int` (frame count).

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import ImageIO
import RecRecCore

func registerGIFExporterTests(_ r: TestRunner) {
    r.test("exports a GIF at 10 fps scaled to the max width") {
        let video = SyntheticMedia.tempURL("mp4")
        let w = try RecordingWriter(configuration: WriterConfiguration(
            outputURL: video, container: .mp4,
            videoSettings: EncoderConfig.videoSettings(codec: .h264, tier: .balanced, scale: .standard, width: 1600, height: 900, frameRate: 30),
            audioTracks: [], clock: CMClockGetHostTimeClock(), automaticHeartbeat: false))
        for i in 0..<60 { w.appendVideo(SyntheticMedia.pixelBuffer(width: 1600, height: 900, frame: i), presentationTime: CMTime(value: CMTimeValue(i), timescale: 30), status: .complete) }
        _ = try await w.finish(at: CMTime(value: 60, timescale: 30))
        let gif = SyntheticMedia.tempURL("gif")
        var lastProgress = 0.0
        let frames = try await GIFExporter.export(video: video, to: gif, options: GIFExportOptions(framesPerSecond: 10, maxWidth: 800)) { lastProgress = $0 }
        try expectEqual(frames, 20)
        try expectNear(lastProgress, 1.0, tolerance: 0.001)
        let source = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        try expectEqual(CGImageSourceGetCount(source), 20)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        try expectEqual(props[kCGImagePropertyPixelWidth] as? Int, 800)
        try expectEqual(props[kCGImagePropertyPixelHeight] as? Int, 450)
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public struct GIFExportOptions {
    public var framesPerSecond: Int
    public var maxWidth: Int
    public init(framesPerSecond: Int = 10, maxWidth: Int = 1200) {
        self.framesPerSecond = framesPerSecond; self.maxWidth = maxWidth
    }
}

public enum GIFExporter {
    /// Decodes `video` at `framesPerSecond`, scales frames to at most `maxWidth`, writes an animated GIF.
    /// Returns the number of frames written. The output is removed on failure.
    @discardableResult
    public static func export(video: URL, to gifURL: URL, options: GIFExportOptions = GIFExportOptions(),
                              progress: ((Double) -> Void)? = nil) async throws -> Int {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecRecError.exportFailed("no video track")
        }
        let size = try await track.load(.naturalSize)
        let scale = min(1, Double(options.maxWidth) / Double(size.width))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = target
        let frameDuration = 1.0 / Double(options.framesPerSecond)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: frameDuration / 2, preferredTimescale: 600)

        let frameCount = max(1, Int((duration / frameDuration).rounded(.down)))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) * frameDuration, preferredTimescale: 600) }

        guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw RecRecError.exportFailed("could not create \(gifURL.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDuration]] as CFDictionary

        var written = 0
        do {
            for await result in generator.images(for: times) {
                let image = try result.image
                CGImageDestinationAddImage(destination, image, frameProperties)
                written += 1
                progress?(Double(written) / Double(frameCount))
            }
            guard CGImageDestinationFinalize(destination) else { throw RecRecError.exportFailed("could not finalize GIF") }
        } catch {
            try? FileManager.default.removeItem(at: gifURL)
            throw RecRecError.exportFailed(error.localizedDescription)
        }
        progress?(1)
        return written
    }
}
```

- [ ] **Step 4: Run tests** — PASS (if `images(for:)` yields fewer frames near the end because of tolerance, use `requestedTimeToleranceAfter = .zero` and re-run).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add GIF export"`

---

### Task 8: App shell — status item, menu, settings wiring, bundle

**Files:**
- Replace: `Sources/RecRec/main.swift`
- Create: `Sources/RecRec/AppDelegate.swift`, `Sources/RecRec/StatusMenuController.swift`, `Sources/RecRec/Permissions.swift`, `Sources/RecRec/LaunchAtLogin.swift`

**Interfaces:**
- Consumes: `SettingsStore`, `RecordingSettings`, enums.
- Produces: `StatusMenuController(store:recorder:)` with `func refresh()`; `Permissions.presentError(_:)`, `Permissions.presentScreenRecordingDenied()`, `Permissions.presentMicrophoneDenied()`; `LaunchAtLogin.isEnabled`, `LaunchAtLogin.setEnabled(_:) throws`. The recorder used here is the `ScreenRecorder` from Task 10; for this task create it with the protocol below so the menu compiles before Task 10:

`Sources/RecRec/RecorderProtocol.swift` (create in this task):

```swift
import Foundation
import RecRecCore

enum RecorderState: Equatable { case idle, preparing, recording(since: Date), stopping }

@MainActor
protocol Recorder: AnyObject {
    var state: RecorderState { get }
    var onStateChange: ((RecorderState) -> Void)? { get set }
    var onFinished: ((Result<RecordingResult, Error>) -> Void)? { get set }
    func start(settings: RecordingSettings) async throws
    func stop() async
}
```

- [ ] **Step 1: main.swift and AppDelegate**

`Sources/RecRec/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

`Sources/RecRec/AppDelegate.swift`:

```swift
import AppKit
import RecRecCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var recorder: ScreenRecorder!
    private var menu: StatusMenuController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder = ScreenRecorder()
        menu = StatusMenuController(store: store, recorder: recorder)
        hotKey = HotKey { [weak self] in self?.menu.toggleRecording() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard case .recording = recorder.state else { return .terminateNow }
        Task { @MainActor in
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

(`ScreenRecorder` and `HotKey` are created in Tasks 10 and 12. Until then, keep this file compiling by adding temporary stubs in `Sources/RecRec/Stubs.swift`:

```swift
import Foundation
import RecRecCore

@MainActor
final class ScreenRecorder: Recorder {
    var state: RecorderState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((RecorderState) -> Void)?
    var onFinished: ((Result<RecordingResult, Error>) -> Void)?
    func start(settings: RecordingSettings) async throws { state = .recording(since: Date()) }
    func stop() async { state = .idle }
}

final class HotKey { init(handler: @escaping () -> Void) {} }
```

Delete `Stubs.swift` in Task 10/12 when the real types land.)

- [ ] **Step 2: Permissions and LaunchAtLogin helpers**

`Sources/RecRec/Permissions.swift`:

```swift
import AppKit

@MainActor
enum Permissions {
    static let screenCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    static func presentError(_ error: Error, title: String = "RecRec") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func presentScreenRecordingDenied() {
        presentSettingsAlert(
            title: "Screen Recording permission needed",
            text: "Allow RecRec under System Settings → Privacy & Security → Screen & System Audio Recording, then start again. macOS may ask you to quit and reopen RecRec.",
            url: screenCaptureSettingsURL)
    }

    static func presentMicrophoneDenied() {
        presentSettingsAlert(
            title: "Microphone permission needed",
            text: "Allow RecRec under System Settings → Privacy & Security → Microphone, or turn the Microphone option off.",
            url: microphoneSettingsURL)
    }

    private static func presentSettingsAlert(title: String, text: String, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
}
```

`Sources/RecRec/LaunchAtLogin.swift`:

```swift
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
```

- [ ] **Step 3: StatusMenuController**

`Sources/RecRec/StatusMenuController.swift`:

```swift
import AppKit
import RecRecCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: SettingsStore
    private let recorder: Recorder
    private var settings: RecordingSettings
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var elapsedTimer: Timer?
    private var lastResult: RecordingResult?
    private var exportInProgress = false
    private var displays: [(id: UInt32, name: String)] = []

    init(store: SettingsStore, recorder: Recorder) {
        self.store = store
        self.recorder = recorder
        self.settings = store.load()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        recorder.onStateChange = { [weak self] state in self?.stateChanged(state) }
        recorder.onFinished = { [weak self] result in self?.recordingFinished(result) }
        updateStatusButton()
        rebuildMenu()
    }

    // MARK: - Actions

    func toggleRecording() {
        switch recorder.state {
        case .idle: startRecording()
        case .recording: Task { await recorder.stop() }
        default: break
        }
    }

    private func startRecording() {
        let settings = self.settings
        Task { @MainActor in
            do { try await recorder.start(settings: settings) }
            catch { presentStartError(error) }
        }
    }

    private func presentStartError(_ error: Error) {
        if let e = error as? RecorderError {
            switch e {
            case .screenRecordingDenied: Permissions.presentScreenRecordingDenied(); return
            case .microphoneDenied: Permissions.presentMicrophoneDenied(); return
            default: break
            }
        }
        Permissions.presentError(error, title: "Could not start recording")
    }

    @objc private func toggleRecordingAction(_ sender: Any?) { toggleRecording() }
    @objc private func toggleMicrophone(_ sender: Any?) { settings.microphoneEnabled.toggle(); if settings.microphoneEnabled { requestMicrophoneIfNeeded() }; save() }
    @objc private func toggleSystemAudio(_ sender: Any?) { settings.systemAudioEnabled.toggle(); save() }
    @objc private func toggleCursor(_ sender: Any?) { settings.showsCursor.toggle(); save() }
    @objc private func toggleReveal(_ sender: Any?) { settings.revealInFinder.toggle(); save() }
    @objc private func selectQuality(_ sender: NSMenuItem) { settings.quality = sender.representedObject as! QualityTier; save() }
    @objc private func selectFormat(_ sender: NSMenuItem) {
        let pair = sender.representedObject as! [String]
        settings.container = Container(rawValue: pair[0])!; settings.codec = VideoCodec(rawValue: pair[1])!; save()
    }
    @objc private func selectFrameRate(_ sender: NSMenuItem) { settings.frameRate = sender.representedObject as! Int; save() }
    @objc private func selectResolution(_ sender: NSMenuItem) { settings.resolution = sender.representedObject as! ResolutionScale; save() }
    @objc private func selectDisplay(_ sender: NSMenuItem) { settings.pinnedDisplayID = sender.representedObject as? UInt32; save() }
    @objc private func selectFolder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { settings.saveDirectory = url; save(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { settings.saveDirectory = url; save() }
    }
    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do { try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) } catch { Permissions.presentError(error, title: "Launch at Login") }
        rebuildMenu()
    }
    @objc private func openLast(_ sender: Any?) { if let url = lastResult?.url { NSWorkspace.shared.open(url) } }
    @objc private func revealLast(_ sender: Any?) { if let url = lastResult?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func exportGIF(_ sender: Any?) {
        guard let url = lastResult?.url, !exportInProgress else { return }
        exportInProgress = true; rebuildMenu()
        let gif = OutputNaming.gifURL(for: url)
        Task { @MainActor in
            do {
                try await GIFExporter.export(video: url, to: gif)
                NSWorkspace.shared.activateFileViewerSelecting([gif])
            } catch { Permissions.presentError(error, title: "GIF export failed") }
            exportInProgress = false; rebuildMenu()
        }
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func requestMicrophoneIfNeeded() {
        Task { @MainActor in
            let granted = await MicrophoneCapture.requestAccess()
            if !granted { settings.microphoneEnabled = false; save(); Permissions.presentMicrophoneDenied() }
        }
    }

    private func save() { store.save(settings); rebuildMenu() }

    // MARK: - State

    private func stateChanged(_ state: RecorderState) {
        updateStatusButton()
        rebuildMenu()
        elapsedTimer?.invalidate(); elapsedTimer = nil
        if case .recording = state {
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatusButton() }
            }
        }
    }

    private func recordingFinished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .success(let r):
            lastResult = r
            if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
        case .failure(let error):
            Permissions.presentError(error, title: "Recording stopped with an error")
        }
        rebuildMenu()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        switch recorder.state {
        case .recording(let since):
            let elapsed = Int(Date().timeIntervalSince(since))
            let text = String(format: "● %02d:%02d", elapsed / 60, elapsed % 60)
            button.image = nil
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ])
        case .preparing, .stopping:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "RecRec busy")
        case .idle:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "RecRec")
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) { displays = DisplaySelection.connectedDisplays(); rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let recording: Bool
        switch recorder.state {
        case .recording, .preparing, .stopping: recording = true
        case .idle: recording = false
        }

        let toggle: NSMenuItem
        switch recorder.state {
        case .idle: toggle = item("Start Recording", #selector(toggleRecordingAction(_:)), key: "r")
        case .recording: toggle = item("Stop Recording", #selector(toggleRecordingAction(_:)), key: "r")
        case .preparing: toggle = item("Starting…", nil)
        case .stopping: toggle = item("Saving…", nil)
        }
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(check("Microphone", settings.microphoneEnabled, #selector(toggleMicrophone(_:)), enabled: !recording))
        menu.addItem(check("System Audio", settings.systemAudioEnabled, #selector(toggleSystemAudio(_:)), enabled: !recording))
        menu.addItem(check("Show Cursor", settings.showsCursor, #selector(toggleCursor(_:)), enabled: !recording))
        menu.addItem(.separator())

        let quality = submenu("Quality", enabled: !recording)
        for (tier, name) in [(QualityTier.small, "Small"), (.balanced, "Balanced"), (.high, "High")] {
            quality.submenu!.addItem(radio(name, settings.quality == tier, #selector(selectQuality(_:)), tier))
        }
        menu.addItem(quality)

        let format = submenu("Format", enabled: !recording)
        for (container, codec, name) in [(Container.mp4, VideoCodec.hevc, "MP4 · HEVC (smallest)"), (.mp4, .h264, "MP4 · H.264 (most compatible)"), (.mov, .hevc, "MOV · HEVC"), (.mov, .h264, "MOV · H.264")] {
            format.submenu!.addItem(radio(name, settings.container == container && settings.codec == codec, #selector(selectFormat(_:)), [container.rawValue, codec.rawValue]))
        }
        menu.addItem(format)

        let fps = submenu("Frame Rate", enabled: !recording)
        for rate in RecordingSettings.frameRateChoices {
            fps.submenu!.addItem(radio("\(rate) fps", settings.frameRate == rate, #selector(selectFrameRate(_:)), rate))
        }
        menu.addItem(fps)

        let res = submenu("Resolution", enabled: !recording)
        res.submenu!.addItem(radio("Retina (native pixels)", settings.resolution == .retina, #selector(selectResolution(_:)), ResolutionScale.retina))
        res.submenu!.addItem(radio("Standard (1x, smaller files)", settings.resolution == .standard, #selector(selectResolution(_:)), ResolutionScale.standard))
        menu.addItem(res)

        if displays.count > 1 {
            let disp = submenu("Display", enabled: !recording)
            disp.submenu!.addItem(radio("Screen under the mouse", settings.pinnedDisplayID == nil, #selector(selectDisplay(_:)), nil))
            for d in displays {
                disp.submenu!.addItem(radio(d.name, settings.pinnedDisplayID == d.id, #selector(selectDisplay(_:)), d.id))
            }
            menu.addItem(disp)
        }
        menu.addItem(.separator())

        if let last = lastResult {
            let size = ByteCountFormatter.string(fromByteCount: last.fileSize, countStyle: .file)
            let lastItem = submenu("Last: \(last.url.lastPathComponent) (\(size))", enabled: true)
            lastItem.submenu!.addItem(item("Open", #selector(openLast(_:))))
            lastItem.submenu!.addItem(item("Reveal in Finder", #selector(revealLast(_:))))
            let gif = item(exportInProgress ? "Exporting GIF…" : "Export GIF", exportInProgress ? nil : #selector(exportGIF(_:)))
            lastItem.submenu!.addItem(gif)
            menu.addItem(lastItem)
        }

        let folder = submenu("Save to: \(settings.saveDirectory.lastPathComponent)", enabled: !recording)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (name, url) in [("Desktop", home.appendingPathComponent("Desktop")), ("Movies", home.appendingPathComponent("Movies")), ("Downloads", home.appendingPathComponent("Downloads"))] {
            folder.submenu!.addItem(radio(name, settings.saveDirectory.standardizedFileURL == url.standardizedFileURL, #selector(selectFolder(_:)), url))
        }
        folder.submenu!.addItem(.separator())
        folder.submenu!.addItem(item("Choose Folder…", #selector(selectFolder(_:))))
        menu.addItem(folder)
        menu.addItem(check("Reveal in Finder After Recording", settings.revealInFinder, #selector(toggleReveal(_:)), enabled: true))
        menu.addItem(.separator())
        menu.addItem(check("Launch at Login", LaunchAtLogin.isEnabled, #selector(toggleLaunchAtLogin(_:)), enabled: true))
        let quit = item("Quit RecRec", #selector(quit(_:)), key: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = action != nil
        return i
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        i.isEnabled = enabled
        return i
    }

    private func radio(_ title: String, _ on: Bool, _ action: Selector, _ value: Any?) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        i.representedObject = value
        return i
    }

    private func submenu(_ title: String, enabled: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = NSMenu(title: title)
        i.submenu!.autoenablesItems = false
        i.isEnabled = enabled
        return i
    }
}
```

Set `menu.autoenablesItems = false` in `init` so `isEnabled` is respected. `RecorderError` (with `.screenRecordingDenied`, `.microphoneDenied`) and `DisplaySelection.connectedDisplays()` are defined in Tasks 9–10; for this task put a minimal `enum RecorderError: LocalizedError { case screenRecordingDenied, microphoneDenied }` and `enum DisplaySelection { static func connectedDisplays() -> [(id: UInt32, name: String)] { [] } }` in `Stubs.swift`, plus `enum MicrophoneCapture { static func requestAccess() async -> Bool { true } }`.

- [ ] **Step 4: Build the bundle and launch it**

Run: `make app && open dist/RecRec.app && sleep 2 && pgrep -x RecRec && osascript -e 'tell application "RecRec" to quit'`
Expected: bundle under 2 MB, the status item appears (record.circle), the menu opens with all sections, process quits cleanly.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add menu-bar app shell with settings menu and bundle packaging"`

---

### Task 9: DisplaySelection and stream configuration helpers

**Files:**
- Create: `Sources/RecRec/DisplaySelection.swift`
- Modify: `Sources/RecRec/Stubs.swift` (remove the `DisplaySelection` stub)

**Interfaces:**
- Produces: `DisplaySelection.connectedDisplays() -> [(id: UInt32, name: String)]`, `DisplaySelection.displayIDUnderMouse() -> CGDirectDisplayID?`, `DisplaySelection.pixelSize(of: CGDirectDisplayID) -> CGSize`, `DisplaySelection.choose(from: [SCDisplay], pinned: UInt32?) -> SCDisplay?`.

- [ ] **Step 1: Implement**

```swift
import AppKit
import ScreenCaptureKit

enum DisplaySelection {
    static func connectedDisplays() -> [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let name = screen.localizedName
            let size = pixelSize(of: id)
            return (id, "\(name) (\(Int(size.width))×\(Int(size.height)))")
        }
    }

    static func displayIDUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func pixelSize(of displayID: CGDirectDisplayID) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    /// Pinned display if still connected, else the display under the mouse, else the main display, else the first.
    static func choose(from displays: [SCDisplay], pinned: UInt32?) -> SCDisplay? {
        if let pinned, let d = displays.first(where: { $0.displayID == pinned }) { return d }
        if let under = displayIDUnderMouse(), let d = displays.first(where: { $0.displayID == under }) { return d }
        if let d = displays.first(where: { $0.displayID == CGMainDisplayID() }) { return d }
        return displays.first
    }
}
```

- [ ] **Step 2: Build** — `swift build` succeeds (stub removed).
- [ ] **Step 3: Commit** — `git add -A && git commit -m "Add display selection helpers"`

---

### Task 10: ScreenRecorder (ScreenCaptureKit orchestration)

**Files:**
- Create: `Sources/RecRec/ScreenRecorder.swift`, `Sources/RecRec/StreamOutputRelay.swift`
- Modify: `Sources/RecRec/Stubs.swift` (remove `ScreenRecorder`, `RecorderError`, keep `HotKey` and `MicrophoneCapture` stubs until Tasks 11–12)

**Interfaces:**
- Consumes: `Recorder` protocol, `RecordingWriter`, `EncoderConfig`, `OutputNaming`, `DiskSpace`, `DisplaySelection`, `MicrophoneCapture` (Task 11: `init(streamClock: CMClock) throws`, `var onSampleBuffer: ((CMSampleBuffer) -> Void)?`, `func start()`, `func stop()`, `static func requestAccess() async -> Bool`, `static var isAuthorized: Bool`).
- Produces: `enum RecorderError: LocalizedError { screenRecordingDenied, microphoneDenied, noDisplay, noMicrophone, streamStopped(String) }`, `final class ScreenRecorder: Recorder`.

- [ ] **Step 1: StreamOutputRelay**

```swift
import Foundation
import ScreenCaptureKit
import RecRecCore

/// Non-isolated receiver for SCStream callbacks. Holds the writer behind a lock so the
/// main-actor ScreenRecorder never touches it from the capture queue.
final class StreamOutputRelay: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    var onStop: ((Error?) -> Void)?

    func attach(_ writer: RecordingWriter) { lock.lock(); self.writer = writer; lock.unlock() }
    func detach() { lock.lock(); writer = nil; lock.unlock() }

    private var currentWriter: RecordingWriter? { lock.lock(); defer { lock.unlock() }; return writer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer = currentWriter, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            writer.appendVideo(pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), status: Self.frameStatus(of: sampleBuffer))
        case .audio:
            writer.appendAudio(sampleBuffer, kind: .system)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> FrameStatus {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return .other }
        switch status {
        case .complete: return .complete
        case .idle: return .idle
        default: return .other
        }
    }
}
```

- [ ] **Step 2: ScreenRecorder**

```swift
import AppKit
import ScreenCaptureKit
import AVFoundation
import os
import RecRecCore

enum RecorderError: LocalizedError {
    case screenRecordingDenied
    case microphoneDenied
    case noDisplay
    case noMicrophone
    case streamStopped(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied: return "Screen Recording permission was not granted."
        case .microphoneDenied: return "Microphone permission was not granted."
        case .noDisplay: return "No display is available to record."
        case .noMicrophone: return "No microphone was found."
        case .streamStopped(let reason): return "The capture stopped: \(reason)"
        }
    }
}

@MainActor
final class ScreenRecorder: Recorder {
    private(set) var state: RecorderState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((RecorderState) -> Void)?
    var onFinished: ((Result<RecordingResult, Error>) -> Void)?

    private let relay = StreamOutputRelay()
    private let captureQueue = DispatchQueue(label: "com.barsmike.RecRec.capture", qos: .userInitiated)
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "recorder")
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var microphone: MicrophoneCapture?
    private var activity: NSObjectProtocol?
    private var stopError: Error?

    init() {
        relay.onStop = { [weak self] error in
            Task { @MainActor in await self?.streamDidStop(error) }
        }
    }

    func start(settings: RecordingSettings) async throws {
        guard state == .idle else { return }
        state = .preparing
        do {
            try DiskSpace.ensureFreeSpace(at: settings.saveDirectory)
            if settings.microphoneEnabled {
                guard await MicrophoneCapture.requestAccess() else { throw RecorderError.microphoneDenied }
            }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                log.error("shareable content failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.screenRecordingDenied
            }
            guard let display = DisplaySelection.choose(from: content.displays, pinned: settings.pinnedDisplayID) else {
                throw RecorderError.noDisplay
            }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let geometry = EncoderConfig.captureGeometry(
                pointSize: CGSize(width: display.width, height: display.height),
                pixelSize: DisplaySelection.pixelSize(of: display.displayID),
                scale: settings.resolution)
            let configuration = Self.streamConfiguration(settings: settings, geometry: geometry)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
            let clock = stream.synchronizationClock ?? CMClockGetHostTimeClock()

            var audioTracks: [AudioTrackSpec] = []
            if settings.systemAudioEnabled { audioTracks.append(AudioTrackSpec(kind: .system, settings: EncoderConfig.audioSettings(kind: .system))) }
            if settings.microphoneEnabled { audioTracks.append(AudioTrackSpec(kind: .microphone, settings: EncoderConfig.audioSettings(kind: .microphone))) }
            try FileManager.default.createDirectory(at: settings.saveDirectory, withIntermediateDirectories: true)
            let url = OutputNaming.uniqueURL(in: settings.saveDirectory, container: settings.container, date: Date())
            let writer = try RecordingWriter(configuration: WriterConfiguration(
                outputURL: url, container: settings.container,
                videoSettings: EncoderConfig.videoSettings(codec: settings.codec, tier: settings.quality, scale: settings.resolution,
                                                           width: geometry.width, height: geometry.height, frameRate: settings.frameRate),
                audioTracks: audioTracks, clock: clock))
            writer.onError = { [weak self] error in
                Task { @MainActor in await self?.writerDidFail(error) }
            }

            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: captureQueue)
            if settings.systemAudioEnabled {
                try stream.addStreamOutput(relay, type: .audio, sampleHandlerQueue: captureQueue)
            }
            var microphone: MicrophoneCapture?
            if settings.microphoneEnabled {
                let mic = try MicrophoneCapture(streamClock: clock)
                mic.onSampleBuffer = { [weak writer] buffer in writer?.appendAudio(buffer, kind: .microphone) }
                microphone = mic
            }

            relay.attach(writer)
            try await stream.startCapture()
            microphone?.start()

            self.stream = stream
            self.writer = writer
            self.microphone = microphone
            self.stopError = nil
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Screen recording")
            state = .recording(since: Date())
            log.info("recording started → \(url.lastPathComponent, privacy: .public) \(geometry.width)x\(geometry.height) \(settings.codec.rawValue, privacy: .public) \(settings.quality.rawValue, privacy: .public)")
        } catch {
            relay.detach()
            state = .idle
            throw error
        }
    }

    func stop() async {
        guard case .recording = state, let writer, let stream else { return }
        state = .stopping
        do { try await stream.stopCapture() } catch { log.error("stopCapture: \(error.localizedDescription, privacy: .public)") }
        microphone?.stop()
        relay.detach()
        let endTime = CMClockGetTime(writer.configuration.clock)
        var outcome: Result<RecordingResult, Error>
        do { outcome = .success(try await writer.finish(at: endTime)) } catch { outcome = .failure(error) }
        if case .success = outcome, let stopError { outcome = .failure(stopError) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        self.stream = nil; self.writer = nil; self.microphone = nil
        state = .idle
        onFinished?(outcome)
    }

    private func streamDidStop(_ error: Error?) async {
        guard case .recording = state else { return }
        if let error {
            log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
            let nsError = error as NSError
            // SCStream reports user-initiated stops with this error code; treat it as a normal stop.
            if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userStopped.rawValue {
                stopError = nil
            } else {
                stopError = RecorderError.streamStopped(error.localizedDescription)
            }
        }
        await stop()
    }

    private func writerDidFail(_ error: Error) async {
        guard case .recording = state else { return }
        stopError = error
        await stop()
    }

    static func streamConfiguration(settings: RecordingSettings, geometry: CaptureGeometry) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = geometry.width
        c.height = geometry.height
        c.sourceRect = geometry.sourceRect
        c.scalesToFit = false
        c.captureResolution = geometry.usesNominalResolution ? .nominal : .best
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        c.queueDepth = 5
        c.showsCursor = settings.showsCursor
        c.capturesAudio = settings.systemAudioEnabled
        c.sampleRate = Int(EncoderConfig.audioSampleRate)
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        c.streamName = "RecRec"
        return c
    }
}
```

Remove the `ScreenRecorder` and `RecorderError` stubs. If `SCStreamError.Code.userStopped` does not exist in the 14.2 SDK, use the numeric code `-3817` (`SCStreamErrorUserStopped`) — check with `grep -n "UserStopped" /Library/Developer/CommandLineTools/SDKs/MacOSX14.2.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCError.h`.

- [ ] **Step 3: Build and smoke-launch**

Run: `make app && open dist/RecRec.app`. Expected: launches; choosing Start shows the system Screen Recording prompt on first use (the user must approve; the session cannot). Quit via `osascript -e 'tell application "RecRec" to quit'`.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "Add ScreenCaptureKit recorder with state machine and error handling"`

---

### Task 11: MicrophoneCapture

**Files:**
- Create: `Sources/RecRec/MicrophoneCapture.swift`
- Modify: `Sources/RecRec/Stubs.swift` (remove `MicrophoneCapture` stub)

**Interfaces:**
- Produces: `final class MicrophoneCapture` with `static var isAuthorized: Bool`, `static func requestAccess() async -> Bool`, `init(streamClock: CMClock) throws`, `var onSampleBuffer: ((CMSampleBuffer) -> Void)?`, `func start()`, `func stop()`.

- [ ] **Step 1: Implement**

```swift
import AVFoundation
import CoreMedia
import os

/// Captures the default microphone through AVCaptureSession and re-times each buffer onto the
/// ScreenCaptureKit stream clock so audio lines up with video.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.barsmike.RecRec.microphone", qos: .userInitiated)
    private let streamClock: CMClock
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "microphone")

    init(streamClock: CMClock) throws {
        self.streamClock = streamClock
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.noMicrophone
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
    }

    func start() { queue.async { self.session.startRunning() } }

    func stop() {
        queue.sync { self.session.stopRunning() }
        onSampleBuffer = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = onSampleBuffer else { return }
        guard let sessionClock = session.synchronizationClock, sessionClock !== streamClock else {
            handler(sampleBuffer); return
        }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: sessionClock, to: streamClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if status == noErr, let retimed { handler(retimed) } else { handler(sampleBuffer) }
    }
}
```

- [ ] **Step 2: Build** — `swift build` succeeds; remove the stub; `make app`.
- [ ] **Step 3: Commit** — `git add -A && git commit -m "Add microphone capture re-timed onto the stream clock"`

---

### Task 12: Global hotkey

**Files:**
- Create: `Sources/RecRec/HotKey.swift`
- Delete: `Sources/RecRec/Stubs.swift` (all stubs gone now)

**Interfaces:**
- Produces: `final class HotKey { init(handler: @escaping () -> Void) }` registering ⌃⌥⌘R.

- [ ] **Step 1: Implement**

```swift
import Carbon.HIToolbox
import Foundation

/// Global ⌃⌥⌘R hotkey through Carbon (no Accessibility permission required).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.handler() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5252_4543), id: 1) // 'RREC'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
```

- [ ] **Step 2: Build, launch, verify no crash** — `make app && open dist/RecRec.app`; then quit.
- [ ] **Step 3: Commit** — `git add -A && git commit -m "Add global hotkey and remove stubs"`

---

### Task 13: README, footprint check, final verification

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-09-07-recrec-design.md` only if a decision changed during implementation.

- [ ] **Step 1: Write README.md** covering: what it is (three bullets), install/build (`make app`, `make run`), first-launch permission steps (Screen Recording prompt, relaunch), menu options with defaults, hotkey, expected output sizes (from the benchmark table), why files are small (four bullets), troubleshooting (permission re-prompt after rebuild, `tccutil reset ScreenCapture com.barsmike.RecRec`, signing with `make app SIGN="Apple Development: …"`), manual acceptance checklist, benchmark reproduction (`make bench`), limitations (two audio tracks when both enabled, macOS 14+).

- [ ] **Step 2: Run everything**

```bash
make test && make app && open dist/RecRec.app && sleep 3 && ps -o rss=,pcpu= -p $(pgrep -x RecRec) && osascript -e 'tell application "RecRec" to quit'
```
Expected: all tests pass; bundle < 2 MB; idle RSS < 30 MB. Record the numbers in README.

- [ ] **Step 3: Commit** — `git add -A && git commit -m "Add README with usage, footprint and acceptance checklist"`

---

## Self-review

- **Spec coverage:** §3 features → Tasks 8 (menu, options, last recording, GIF, launch at login), 10 (display choice, exclusion of self, sleep prevention, disk check, permission flow), 11 (mic), 12 (hotkey); §6 encoding → Tasks 3, 6, 10; §7 errors → Tasks 8, 10 (alerts, stream stop, writer failure, quit while recording in AppDelegate); §8 tests → Tasks 2–7; §9 build → Task 1; §10 footprint → Task 13.
- **Placeholders:** none; every code step is complete.
- **Type consistency:** `RecorderState`/`Recorder` (Task 8) are used by `ScreenRecorder` (Task 10) and `StatusMenuController`; `WriterConfiguration.automaticHeartbeat` must be added in Task 6 (see note) and is used in Task 7's test; `MicrophoneCapture` API in Task 11 matches Task 10's usage; `DisplaySelection.connectedDisplays()` (Task 9) is used by the menu.

# RecRec — lightweight macOS screen recorder (design spec)

Date: 2026-09-07
Status: approved autonomously under `/goal` (the user asked for research + build without pauses). Every decision the user did not make explicitly is listed in §11 "Assumptions".

## 1. Goal

A menu-bar macOS app that records the entire screen and writes **small, good-looking MP4 files** by default. Two things must be light:

1. **The app**: native Swift, no third-party dependencies, no Dock icon, no windows, a few MB on disk, tens of MB of RAM, hardware encoding.
2. **The output**: minutes of typical desktop activity should cost a few MB, not the hundreds of MB (or GB) QuickTime produces, while text stays readable.

Non-goals (deliberately excluded, see §3): editing/trimming, window/area capture, webcam, cloud, annotations, click/keystroke overlays, streaming.

## 2. Why QuickTime files are huge, and what fixes it

Built-in recordings (QuickTime / ⇧⌘5) write H.264 `.mov` at a fixed high bitrate with no user control: research found 10–20 Mbps for ordinary Retina desktop content (75–150 MB/min, 4.5–9 GB/h) and up to ~40 Mbps on 5K displays (research-products.md §E). The bitrate is spent even when nothing on screen changes.

Measured on this Mac (M3 Max, 3456×2234, 60 s synthetic desktop scenario: typing, scrolling, idle, mouse, window drag; see `docs/benchmarks/encoder-benchmark.md`):

| Encoder setting | Size (60 s) | PSNR-Y (static text) | Note |
|---|---|---|---|
| H.264 30 Mbps, constant frame rate (QuickTime-like) | 38.2 MB | 53.8 dB | baseline |
| H.264 8 Mbps CFR | 23.1 MB | 54.4 dB | bitrate mode wastes bits on static frames |
| H.264 quality 0.50, variable frame rate | 2.84 MB | 43.4 dB | 13× smaller, text crisp |
| HEVC quality 0.50, VFR | 2.19 MB | 40.8 dB | |
| HEVC quality 0.50, VFR, speed-priority off | **1.86 MB** | **43.5 dB** | 20× smaller than baseline at H.264-0.50 quality |
| HEVC quality 0.40, VFR | 1.72 MB | 38.0 dB | slightly soft at 2x |

Levers, in order of impact:

1. **Constant-quality rate control** (`kVTCompressionPropertyKey_Quality`) instead of an average bitrate: bits go where the picture changes; a static desktop costs almost nothing. This alone is a 10–17× reduction versus a QuickTime-like bitrate.
2. **Variable frame rate**: ScreenCaptureKit reports idle frames; we do not write them. In the benchmark scenario (48% idle) this saved a further 20%. A sparse "heartbeat" frame keeps players happy (§6.4).
3. **HEVC with `PrioritizeEncodingSpeedOverQuality = false`**: on the Apple hardware encoder this is both smaller and sharper than the default (1.86 MB @ 43.5 dB vs 2.19 MB @ 40.8 dB). H.264 stays available for compatibility.
4. **30 fps cap** (60 optional): screen content rarely needs more; halves the worst case.
5. **1x resolution option**: roughly halves the size again (1.10 MB vs 2.19 MB for HEVC 0.50) at the cost of Retina sharpness; off by default.
6. **Small audio**: AAC 64 kbps mono for the microphone, 128 kbps stereo for system audio; audio is off by default.

## 3. Product scope

Inspired by QuickRecorder, Azayaka, BetterCapture, Kap/Aperture, CleanShot X and Screen Studio (research-products.md), reduced to what a full-screen recorder needs.

**Included (v1)**

- Menu-bar item (`LSUIElement`), no Dock icon, no windows. Icon turns into a red dot with elapsed time while recording.
- Start/stop from the menu or a global hotkey ⌃⌥⌘R (Carbon hotkey, no Accessibility permission).
- Records one entire display: the display under the mouse by default, or a pinned display when more than one is connected.
- Options (all in the menu, persisted): Microphone (off), System Audio (off), Show Cursor (on), Quality (Small / Balanced / High), Format (MP4-HEVC default, MP4-H.264, MOV-HEVC, MOV-H.264), Frame Rate (15/24/30/60), Resolution (Retina / Standard 1x), Display, Save folder (`~/Movies/RecRec` default), Reveal in Finder after recording (on), Launch at Login (off).
- Last recording entry in the menu: Open, Reveal in Finder, Export GIF.
- Crash-safe files: fragmented MP4/MOV (a crash loses at most the last 5 s).
- Excludes its own UI from the capture; prevents display sleep while recording; stops and finalizes when the Mac goes to sleep; refuses to start with < 500 MB free.
- Hardware H.264 cannot encode frames wider than 4096 px (AVAssetWriter silently falls back to software on 5K/6K displays), so H.264 recordings are downscaled to fit 4096×2304; HEVC has no such limit.
- Permission flow: clear alerts with an "Open System Settings" button for Screen Recording and Microphone.

**Later (cheap, not in v1)**: countdown, pause/resume, mixing mic + system audio into one track, click highlight (macOS 15 API), configurable hotkey, exclude specific apps, HDR.

**Never**: editor, zoom effects, cloud/share links, webcam, annotations, plugins, Electron/Tauri, telemetry.

## 4. Tech stack

| Concern | Choice | Why |
|---|---|---|
| Language / UI | Swift 5.9, AppKit (`NSStatusItem`, `NSMenu`, `NSAlert`) | Smallest footprint and most predictable menu-bar behavior; no SwiftUI runtime quirks; SwiftUI is not needed for a menu with toggles. |
| Capture | ScreenCaptureKit `SCStream` (macOS 14 API surface) | GPU-side capture, delivers 4:2:0 frames the encoder consumes without conversion, reports idle frames, captures system audio without a driver. |
| Encoding / muxing | AVFoundation `AVAssetWriter` → VideoToolbox hardware H.264/HEVC, AAC | Direct-to-file, hardware, supports constant-quality mode and movie fragments for MP4 and MOV (verified on this machine). |
| Microphone | `AVCaptureSession` + `AVCaptureAudioDataOutput` | Delivers ready `CMSampleBuffer`s with a clock we can convert to the stream clock; works on macOS 14 (the SCStream microphone API is macOS 15+ and not in the available SDK). |
| Hotkey | Carbon `RegisterEventHotKey` | No Accessibility permission, ~40 lines. |
| Persistence | `UserDefaults` | A dozen keys. |
| Build | Swift Package Manager + `Makefile` that assembles `RecRec.app` (Info.plist, ad-hoc codesign) | No Xcode installed on this machine; keeps the repo tiny. |
| Tests | Custom test executable (`swift run RecRecTests`) | XCTest is unavailable with Command Line Tools only. |
| Deployment target | macOS 14.0, Apple Silicon (Intel build via `make UNIVERSAL=1`) | The SDK available is 14.2; macOS 14 has everything needed. |

Rejected: Electron/Tauri (100–400 MB, RAM heavy), Rust bindings (no benefit over Swift here), `SCRecordingOutput` (macOS 15+, no bitrate/quality control), software x264 (CPU heavy, not lighter).

## 5. Architecture

```
┌──────────────────────── RecRec (executable, AppKit) ────────────────────────┐
│ AppDelegate ── StatusMenuController ── HotKey                                │
│        │                │                                                     │
│        └──── ScreenRecorder (state machine) ──┬── SCStream (video, sys audio)│
│                       │                       └── MicrophoneCapture (AVCap.) │
│                       ▼                                                       │
│              RecordingWriter (RecRecCore) ── AVAssetWriter → .mp4/.mov        │
└───────────────────────────────────────────────────────────────────────────────┘
RecRecCore (library, no AppKit): Settings, EncoderConfig, FrameGate, RecordingWriter,
                                 OutputNaming, GIFExporter, DiskSpace
RecRecTests (executable): custom harness exercising RecRecCore with synthetic frames
```

### 5.1 Components

**Settings (RecRecCore)** — `struct RecordingSettings: Codable, Equatable` with enums `VideoCodec {h264, hevc}`, `Container {mp4, mov}`, `QualityTier {small, balanced, high}`, `ResolutionScale {retina, standard}`, `frameRate: Int`, booleans for mic/system audio/cursor/reveal, `saveDirectory: URL`, `pinnedDisplayID: UInt32?`. `SettingsStore` loads/saves via `UserDefaults` (JSON blob under one key), falling back to defaults on any decode error. Pure value type, fully testable.

**EncoderConfig (RecRecCore)** — pure functions:
- `videoSettings(codec:, tier:, scale:, width:, height:, frameRate:) -> [String: Any]` builds the `AVAssetWriterInput` output settings (§6.1). Guarantees even dimensions.
- `audioSettings(kind: .microphone | .system, sampleRate:, channels:) -> [String: Any]`.
- `captureDimensions(displayPixelSize:, scale:) -> (width, height, sourceRect)` with even rounding by cropping (never scaling) one row/column.

**FrameGate (RecRecCore)** — decides for each incoming frame `append`, `skip`; and for the heartbeat timer `repeatLast` when the last written frame is older than the heartbeat interval. Input: frame status (complete/idle/other), presentation time, last appended time. Pure, testable.

**RecordingWriter (RecRecCore)** — owns `AVAssetWriter`, one video input (+ pixel buffer adaptor), optional audio inputs (microphone, system), a serial `DispatchQueue`, the heartbeat `DispatchSourceTimer`, and the `CMClock` used for "now".
- `init(configuration:)` creates the file, sets `movieFragmentInterval = 5 s`, `shouldOptimizeForNetworkUse = false`, `expectsMediaDataInRealTime = true`.
- `appendVideo(pixelBuffer, presentationTime, status)` starts the session at the first complete frame's PTS; applies FrameGate; wraps the pixel buffer in a `CMSampleBuffer` with an explicit duration of one frame (`1/fps`) and appends it; retains the last pixel buffer for heartbeats.
- `appendAudio(sampleBuffer, kind)` drops audio until the session started and buffers that end before the session start. The AAC converter is configured from the first buffer, so later buffers are compared with it: a description that differs only cosmetically (observed in the field: AirPods deliver the first mono buffer as "interleaved" and the rest as "non-interleaved", byte-identical) is re-wrapped under the first description; a real change (rate, channels, bit depth) is dropped and counted.
- `finish(at endTime) async throws -> RecordingResult {url, duration, fileSize, videoFrames}` re-appends the last frame at `max(endTime, last + 1/fps)` with an explicit one-frame duration, marks inputs finished, `endSession(atSourceTime: finalFrameEnd)`, `finishWriting`. The explicit duration matters: AVAssetWriter gives the last sample the previous inter-frame delta when its duration is invalid (a 2 s heartbeat gap would become a 2 s frozen tail), and `endSession` only extends the edit list, which ffmpeg-based players ignore. With a real final frame every player agrees on the duration.
- Any writer failure is surfaced through `finish` (throws) and through an `onError` callback so the recorder can stop early; the fragmented file remains playable.

**OutputNaming (RecRecCore)** — `Recording 2026-09-07 at 22.41.05.mp4` (24-hour, sortable); appends ` 2`, ` 3`… on collision.

**GIFExporter (RecRecCore)** — reads a recording with `AVAssetImageGenerator` at 10 fps, scales to ≤ 1200 px wide, writes an animated GIF through ImageIO (`CGImageDestination`, loop forever, per-frame delay). Reports progress (0…1) through a callback; cancellable.

**DiskSpace (RecRecCore)** — free bytes for a directory's volume via `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`.

**ScreenRecorder (app)** — state machine `idle → preparing → recording → stopping → idle`, all transitions on the main actor; capture callbacks on a private serial queue.
- `start(settings:)`: checks disk space, resolves the display (pinned → mouse → main), asks `SCShareableContent` (this triggers the system permission prompt on first use), builds `SCContentFilter(display:excludingApplications:[self] exceptingWindows:[])`, `SCStreamConfiguration` (§6.2), creates `RecordingWriter`, starts `MicrophoneCapture` if enabled, `stream.startCapture()`, begins the sleep-prevention activity, starts the elapsed timer.
- `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`: `.screen` → read `SCStreamFrameInfo.status` attachment + image buffer → `writer.append(video…)`; `.audio` → `writer.append(audio…, track: .system)`.
- `SCStreamDelegate.stream(_:didStopWithError:)` (display unplugged, user stopped from the system indicator, sleep) → `stop(reason: .streamStopped(error))` finalizes normally and reports.
- `stop()`: `stream.stopCapture()`, mic stop, `writer.finish(at: clock.time)`, end activity, publish `RecordingResult` to the menu, reveal in Finder if enabled.

**MicrophoneCapture (app)** — `AVCaptureSession` with the default audio device and `AVCaptureAudioDataOutput` on a serial queue; each buffer's PTS is converted from the session's `synchronizationClock` to the stream's `synchronizationClock` with `CMSyncConvertTime` before being appended as the `.microphone` track. Requests microphone permission when the option is turned on and again at start if needed.

**StatusMenuController (app)** — builds the `NSMenu` from `RecordingSettings`, reflects state (check marks, disabled items while recording, elapsed time in the status button title), routes actions to `ScreenRecorder` and `SettingsStore`. Shows `NSAlert`s for errors (with "Open System Settings" for permissions).

**HotKey (app)** — registers ⌃⌥⌘R; toggles start/stop on the main actor.

**AppDelegate (app)** — `applicationShouldTerminate` returns `.terminateLater` while a recording is being finalized so the file is never left unfinished; SIGTERM/quit during recording stops and finishes first.

### 5.2 Data flow (recording)

1. User → Start. `ScreenRecorder` prepares (permissions, display, writer) and starts `SCStream`.
2. SCK delivers 4:2:0 frames at ≤ fps on the capture queue. `FrameGate` drops idle frames; complete frames go to `AVAssetWriterInputPixelBufferAdaptor` with their SCK presentation time.
3. Heartbeat timer (every 2 s, writer queue): if the last written frame is older than 2 s, re-append it at "now" (stream clock).
4. Audio buffers (system from SCK, mic from AVCaptureSession) are appended to their own AAC inputs after the session has started.
5. User → Stop (or the stream stops). The writer appends the final frame at the stop time, finishes, and returns `{url, duration, size}`; the menu shows "Last recording … (2.3 MB)" and Finder reveals the file.

### 5.3 Threads and clocks

- All UI/state on the main actor. SCK callbacks on `captureQueue` (serial, user-initiated QoS). Writer work on `writerQueue` (serial). The capture queue calls into the writer synchronously; the writer's queue is only used for the heartbeat timer and finish. (One serial queue for both is acceptable; two keep the timer from contending with frame delivery.)
- All timestamps are in the `SCStream.synchronizationClock` domain. Mic timestamps are converted with `CMSyncConvertTime`. The heartbeat and the final frame use `CMClockGetTime(streamClock)`.

## 6. Encoding design ("smart small outputs")

### 6.1 Video settings (AVAssetWriter)

```swift
[
  AVVideoCodecKey: .hevc | .h264,
  AVVideoWidthKey: w, AVVideoHeightKey: h,            // even
  AVVideoColorPropertiesKey: [primaries: 709, transfer: 709, matrix: 709],
  AVVideoCompressionPropertiesKey: [
    kVTCompressionPropertyKey_Quality: q,               // tier × scale table below
    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: false,  // HEVC: smaller AND sharper; harmless for H.264
    AVVideoMaxKeyFrameIntervalKey: fps * 10,            // counted in frames, not seconds: idle heartbeats (0.5 fps) then cost tiny P-frames, not a keyframe every 10 s
    AVVideoAllowFrameReorderingKey: false,              // B-frames never helped screen content: 4–9% larger at equal PSNR
    AVVideoExpectedSourceFrameRateKey: fps,
    kVTCompressionPropertyKey_RealTime: true,
    AVVideoProfileLevelKey: HEVC_Main_AutoLevel | H264_High_AutoLevel (+ CABAC entropy for H.264)
  ]
]
```

Quality tiers (VideoToolbox quality 0…1). Values were chosen from the sweep in `docs/benchmarks/encoder-benchmark.md` so that each tier reaches about the same PSNR on static UI text regardless of codec and scale (Small ≈ 40 dB, Balanced ≈ 43.5 dB, High ≈ 48–50 dB):

| Tier | HEVC 2x | HEVC 1x | H.264 2x | H.264 1x | Intent |
|---|---|---|---|---|---|
| Small | 0.40 | 0.50 | 0.45 | 0.50 | smallest files that keep UI text legible |
| Balanced (default) | 0.50 | 0.55 | 0.50 | 0.60 | visually clean text, ~20× smaller than QuickTime |
| High | 0.65 | 0.70 | 0.65 | 0.70 | near-transparent |

Measured for the 60 s scenario, Balanced: HEVC 2x 1.78 MB, HEVC 1x 1.17 MB, H.264 2x 2.59 MB.

No average-bitrate or data-rate-limit keys: the benchmark showed `DataRateLimits` changes the rate control and produced larger files.

### 6.2 Capture configuration (SCStreamConfiguration)

- `width/height`: display pixel size (Retina) or point size (1x), cropped to even numbers through `sourceRect`; `captureResolution = .best` (Retina) / `.nominal` (1x); `scalesToFit = false`.
- `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ('420v'): the encoder's native input, no conversion pass. `colorSpaceName = sRGB`, `colorMatrix = ITU_R_709_2` (matching the 709 tags written to the file so colors are not washed out).
- `minimumFrameInterval = 1/fps`, `queueDepth = 6` (one slot is permanently held by the retained last frame used for heartbeats), `showsCursor` per settings.
- `capturesAudio` per settings, `sampleRate = 48000`, `channelCount = 2`, `excludesCurrentProcessAudio = true`.
- Content filter excludes RecRec's own process (no timer in the recording).

### 6.3 Audio settings

- Microphone: AAC-LC, 48 kHz, mono, 64 kbps.
- System audio: AAC-LC, 48 kHz, stereo, 128 kbps.
- Both enabled → two audio tracks in v1 (QuickTime plays both; mixing is a listed follow-up).

### 6.4 Variable frame rate, heartbeat, fragments

- Idle frames (`SCFrameStatus.idle`, or no image buffer) are skipped. ScreenCaptureKit can also go completely silent on a static screen, so the heartbeat is timer-driven: a frame is re-appended when nothing was written for 2 s, so no frame duration exceeds ~2 s (players and editors then see a normal stream, and a seek never has to decode more than 10 s of tiny duplicate frames). Measured cost of a 1 s heartbeat on a 48%-idle minute: +5% (≈100 KB/min); 2 s halves that.
- Keyframes are limited by frame count (`fps × 10` frames), not by duration, so idle periods do not pay for a full-frame keyframe every 10 s.
- `movieFragmentInterval = 5 s` for both MP4 and MOV. Verified: a process killed mid-recording leaves a playable file missing at most the last fragment; without fragments the file is unreadable ("moov atom not found"). Overhead measured at < 1%.
- `finish(at:)` always appends the last frame at the stop time so an idle tail is preserved.

### 6.5 Expected sizes (Balanced, Retina, 30 fps, no audio)

From the benchmark scenario: ≈ 1.8 MB per minute of mixed desktop activity; a fully static screen costs ≈ 0.1 MB/min; continuous scrolling ≈ 5 MB/min; full-screen video playback is the worst case (≈ 10–20 MB/min, still 5–10× below QuickTime). Standard (1x) roughly halves each figure.

## 7. Error handling

| Situation | Behavior |
|---|---|
| Screen Recording not granted | `SCShareableContent` fails → alert "RecRec needs Screen Recording permission" with "Open System Settings" (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`) and a note that macOS may require relaunching. State back to idle. |
| Microphone denied while the option is on | Alert with "Open System Settings"; recording is not started (the user can turn the mic off). |
| < 500 MB free on the target volume | Alert; not started. |
| Stream stops on its own (display removed, user pressed Stop in the system indicator) | Finalize normally; the menu shows the result; if an error other than "user stopped" is attached, an alert explains it. |
| Mac goes to sleep (`NSWorkspace.willSleepNotification`) | Stop and finalize before sleep (ScreenCaptureKit streams do not survive sleep reliably). |
| Writer fails mid-recording (disk full, encoder error) | Stop capture, finalize what exists, alert with the file location and the error. |
| Quit while recording | Stop and finalize before terminating. |
| GIF export failure | Alert; partial file removed. |

Every error reaches the user as an `NSAlert` with a specific message; nothing is swallowed. Logging through `os.Logger` (subsystem `com.barsmike.RecRec`).

## 8. Testing

- **Unit (custom harness, `make test`)**: Settings defaults/round-trip/invalid JSON; EncoderConfig (keys, even dimensions, tier table, crop rects); FrameGate decisions; OutputNaming collisions; DiskSpace sanity.
- **Integration with synthetic media (no permissions needed)**: `RecordingWriter` fed with generated pixel buffers → verify with `AVAsset`: playable, duration equals the session length with an idle tail, frame count reflects skipped frames + heartbeat, HEVC and H.264, MP4 and MOV, fragments present (`moof` atoms) and a file left unfinished is readable; audio track present when synthetic PCM sample buffers are appended; `GIFExporter` produces a GIF with the expected frame count.
- **Manual acceptance (needs the user, TCC)**: first launch permission flow, hotkey, timer, microphone, two displays, sleep prevention, file plays in QuickTime/Chrome, sizes match §6.5. Recorded in README as a checklist.
- **Footprint check**: `make app` prints the binary size; the README documents measured RSS while idle/recording.

## 9. Build and distribution

- `make app` → `swift build -c release`, assemble `dist/RecRec.app` (Info.plist with `LSUIElement`, `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable`), `codesign --sign -` (ad-hoc). `make run` opens it. `make test` runs the harness. `make bench` runs the encoder benchmark tool.
- Ad-hoc signing means macOS re-asks for Screen Recording after each rebuild; the README documents how to use a self-signed or Apple Development identity (`make app SIGN=...`) to avoid that.

## 10. Footprint targets

Binary < 2 MB; idle RSS < 50 MB; recording CPU < 15% of one core on Apple Silicon (hardware encode; no pixel conversion in software).

Measured on 2026-09-08 (release build, M3 Max, macOS 26.6): bundle 552 KB, idle RSS 44 MB at 0% CPU. Recording CPU could not be measured from the autonomous session because Screen Recording permission requires the user to click the system prompt.

## 11. Assumptions made autonomously

1. Audio is off by default (user: "por default somente a tela"); the product research's "system audio on" default was overridden by the user's request.
2. HEVC-in-MP4 is the default format because the user's priority is size; H.264 is one click away for Windows/old-browser recipients.
3. Retina (native) resolution is the default so text stays sharp; 1x is the size-saver option.
4. "Export in various types" is satisfied by MP4/MOV × HEVC/H.264 at record time plus GIF export; WebM/MKV would require bundling ffmpeg (100+ MB) and were excluded.
5. Save folder defaults to `~/Movies/RecRec` (writing to Desktop/Documents/Downloads triggers an extra macOS "access your Desktop folder" prompt on first recording; Movies does not); the menu offers Desktop/Downloads/Movies/Choose…; file name `Recording YYYY-MM-DD at HH.mm.ss`.
6. Hotkey fixed at ⌃⌥⌘R (no conflicts with macOS shortcuts); not user-rebindable in v1.
7. UI language English.
8. macOS 14 minimum (SDK 14.2 is what the machine has); macOS 15-only features (mic through SCK, click highlight) are deferred.
9. Two audio tracks when both mic and system audio are enabled (mixing deferred).
10. Keyframe cadence 10 s of written frames (a 30 s cadence would save ~15% more but slows scrubbing); the research suggestion of 2 s was rejected because it doubles file size in the benchmark.
11. H.264 above 4096 px wide is downscaled to fit rather than switched to HEVC, so the user's explicit compatibility choice is respected.

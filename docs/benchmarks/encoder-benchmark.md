# Encoder benchmark (2026-09-07)

Machine: MacBook Pro M3 Max, macOS 26.6, built-in display 3456×2234 (1728×1117 points). Hardware encoders `com.apple.videotoolbox.videoencoder.ave.hevc` / `ave.avc`.

Tool: `tools/encbench/encbench.swift` renders a deterministic 60 s "desktop" scenario at 30 fps and feeds every frame to several `AVAssetWriter` configurations at once, so all outputs see identical input. No Screen Recording permission is needed. `tools/encbench/quality.sh` extracts one decoded frame per configuration at t = 5 s, 15 s and 45 s and compares it with the rendered reference frame (PSNR on luma, SSIM) using ffmpeg.

Scenario timeline (what a real desktop does):

| Time | Content | Frames that change |
|---|---|---|
| 0–10 s | typing in an editor (4 chars/s) | 4 per second |
| 10–20 s | smooth scrolling of code (480 px/s) | every frame |
| 20–30 s | nothing | none |
| 30–40 s | mouse moving in a circle | every frame (tiny area) |
| 40–50 s | dragging a window | every frame |
| 50–60 s | nothing | none |

940 of 1800 frames change (52%). The frame is a full-screen mockup: wallpaper gradient, menu bar, editor window with syntax-coloured code and line numbers, sidebar, dock, cursor.

## Results — Retina 3456×2234, 60 s

"VFR" = idle frames skipped (only changed frames written, plus one final frame). PSNR/SSIM measured on the static typing frame at t = 5 s (the other two instants agree within 0.5 dB).

| Configuration | Size | MB/min | PSNR-Y | SSIM |
|---|---|---|---|---|
| H.264 30 Mbps, CFR, 1 s keyframes (QuickTime-like) | 38.2 MB | 38.2 | 53.8 | 0.9987 |
| H.264 8 Mbps, CFR | 23.1 MB | 23.1 | 54.4 | 0.9986 |
| H.264 3 Mbps, VFR | 13.3 MB | 13.3 | 47.6 | 0.9979 |
| HEVC 2 Mbps, VFR | 8.5 MB | 8.5 | 45.8 | 0.9972 |
| H.264 quality 0.70, VFR | 5.45 MB | 5.5 | 52.3 | 0.9982 |
| H.264 quality 0.65, VFR | 4.29 MB | 4.3 | 49.7 | 0.9978 |
| H.264 quality 0.60, VFR | 3.80 MB | 3.8 | 48.1 | 0.9974 |
| H.264 quality 0.55, VFR | 3.64 MB | 3.6 | 46.1 | 0.9970 |
| H.264 quality 0.50, CFR | 3.50 MB | 3.5 | 43.4 | 0.9955 |
| H.264 quality 0.50, VFR | 2.84 MB | 2.8 | 43.4 | 0.9957 |
| H.264 quality 0.50, VFR, no B-frames | 2.59 MB | 2.6 | 43.4 | 0.9956 |
| H.264 quality 0.45, VFR | 2.53 MB | 2.5 | 41.5 | 0.9946 |
| HEVC quality 0.70, VFR | 5.36 MB | 5.4 | 48.4 | 0.9981 |
| HEVC quality 0.60, VFR | 3.31 MB | 3.3 | 44.4 | 0.9969 |
| HEVC quality 0.50, CFR | 2.80 MB | 2.8 | 40.8 | 0.9944 |
| HEVC quality 0.50, VFR | 2.19 MB | 2.2 | 40.8 | 0.9944 |
| HEVC quality 0.40, VFR | 1.72 MB | 1.7 | 38.0 | 0.9910 |
| HEVC 0.70, VFR, speed-priority off | 4.36 MB | 4.4 | 52.9 | 0.9983 |
| HEVC 0.65, VFR, speed-priority off | 3.25 MB | 3.3 | 50.1 | 0.9979 |
| HEVC 0.60, VFR, speed-priority off | 2.71 MB | 2.7 | 48.3 | 0.9975 |
| HEVC 0.55, VFR, speed-priority off | 2.40 MB | 2.4 | 46.4 | 0.9970 |
| HEVC 0.50, VFR, speed-priority off | 1.86 MB | 1.9 | 43.5 | 0.9957 |
| HEVC 0.50, VFR, speed-priority off, no B-frames | **1.78 MB** | 1.8 | 43.5 | 0.9957 |
| HEVC 0.50, VFR, speed-priority off, 30 s keyframes | 1.59 MB | 1.6 | 43.5 | 0.9957 |
| HEVC 0.45, VFR, speed-priority off | 1.68 MB | 1.7 | 41.6 | 0.9945 |
| HEVC 0.40, VFR, speed-priority off | 1.54 MB | 1.5 | 39.9 | 0.9932 |

Variants of HEVC 0.50 VFR (speed-priority default) that made no difference: `MaxAllowedFrameQP = 40`, `RealTime = false` / `expectsMediaDataInRealTime = false`. `DataRateLimits` (3 Mbps cap) changed the rate control and made the file 3× larger (6.33 MB). A 2 s keyframe interval doubled the size (4.22 MB).

## Results — Standard 1x, 1728×1116, 60 s

| Configuration | Size | MB/min | PSNR-Y | SSIM |
|---|---|---|---|---|
| H.264 30 Mbps, CFR (QuickTime-like) | 23.2 MB | 23.2 | – | – |
| H.264 quality 0.65, VFR | 2.13 MB | 2.1 | 44.5 | 0.9949 |
| H.264 quality 0.55, VFR | 1.63 MB | 1.6 | 42.2 | 0.9935 |
| H.264 quality 0.50, VFR, no B-frames | 1.10 MB | 1.1 | 40.5 | 0.9916 |
| HEVC 0.70, VFR, speed-priority off | 2.16 MB | 2.2 | 50.3 | 0.9961 |
| HEVC 0.65, VFR, speed-priority off | 1.60 MB | 1.6 | 47.4 | 0.9955 |
| HEVC 0.60, VFR, speed-priority off | 1.32 MB | 1.3 | 45.5 | 0.9947 |
| HEVC 0.55, VFR, speed-priority off | 1.17 MB | 1.2 | 43.5 | 0.9938 |
| HEVC 0.50, VFR, speed-priority off | 0.89 MB | 0.9 | 40.4 | 0.9911 |
| HEVC 0.45, VFR, speed-priority off | 0.80 MB | 0.8 | 38.6 | 0.9894 |
| HEVC 0.40, VFR, speed-priority off | 0.72 MB | 0.7 | 36.6 | 0.9846 |

At 1x the same quality value gives ~3 dB less on text (glyphs are smaller relative to the coding blocks), and 0.40 is visibly blurry, so the 1x tiers use higher values.

## Fragmented output (crash safety)

`AVAssetWriter.movieFragmentInterval` works for `.mp4` as well as `.mov` on macOS 26. A process that exits without `finishWriting` after 6 s leaves a playable file with fragments (4 s recovered at a 2 s interval) and an unreadable file without them ("moov atom not found").

Overhead on the 60 s scenario (HEVC 0.50, speed-priority off): none 1,952,929 B; 10 s 1,966,755 B (+0.7%); 5 s 1,967,231 B (+0.7%); 2 s 1,968,163 B (+0.8%). A 1 s heartbeat frame (re-appending the last frame during idle periods) added +5% (2,074,603 B), i.e. about 100 KB per idle minute at 4K, so the app uses a 2 s heartbeat.

## Decisions taken from these numbers

1. Constant quality (`kVTCompressionPropertyKey_Quality`), never average bitrate: 10–17× smaller than the QuickTime-like baseline on this content.
2. Skip idle frames (VFR): −20% on a half-idle minute, and static screens cost ≈ 0.1 MB/min.
3. HEVC default with `PrioritizeEncodingSpeedOverQuality = false`: +2.7 dB and −15% size versus the default HEVC path; H.264 does not react to that flag.
4. `AllowFrameReordering = false`: 4–9% smaller at identical PSNR, lower latency and memory.
5. Keyframes every 10 s of written video (30 s would save another 15% but makes scrubbing slow).
6. Fragments every 5 s (< 1% overhead), heartbeat every 2 s.
7. Tier table (VideoToolbox quality): HEVC 2x 0.40 / 0.50 / 0.65; HEVC 1x 0.50 / 0.55 / 0.70; H.264 2x 0.45 / 0.50 / 0.65; H.264 1x 0.50 / 0.60 / 0.70 (Small / Balanced / High).

Caveats: the scenario is synthetic (rendered UI, not a captured screen); absolute sizes for real desktops with photos, video or dark themes will differ, but the relative comparisons drive the decisions. Reproduce with `make bench`.

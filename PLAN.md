# Mac Recorder: implementation plan

Personal macOS menu-bar screen recorder. Target macOS 15.0+, Apple silicon, locally signed (Apple Development identity), no sandbox, no notarization.

Plan drafted by a Claude Fable planning agent on 2026-11-25. Reuse research was done by reading the BetterCapture, QuickRecorder and Azayaka sources through the GitHub API. All performance, memory and file-size numbers are estimates until measured at the named milestone.

## 1. Decisions at a glance

| Topic | Decision |
|---|---|
| Capture | One video-only `SCStream` per display or window, plus one dedicated audio `SCStream` |
| System audio | Always from the dedicated audio stream (full-display filter, 2x2 px, 1 fps video discarded) |
| Microphone | `SCStreamConfiguration.captureMicrophone` + `microphoneCaptureDeviceID` on the audio stream (macOS 15), behind a `MicSource` protocol |
| Camera | `AVCaptureSession` + `AVCaptureVideoDataOutput` (composited mode) or `AVCaptureVideoPreviewLayer` (bubble mode) |
| Clock | Host time (`CMClockGetHostTimeClock`) for everything; output time is counter-based |
| Compositor | Core Image on Metal (`CIContext(mtlDevice:)`), rendering into buffers from the writer adaptor's pool |
| Writer | Custom `AVAssetWriter`; never `SCRecordingOutput` |
| Frame rate | Constant, 30 fps default, 60 optional |
| Dynamic range | SDR only (`captureDynamicRange = .SDR`, BT.709 tags) |
| Menu | AppKit `NSStatusItem` + `NSMenu`; SwiftUI only for Settings and Onboarding windows |
| Project | XcodeGen `project.yml` + local Swift package `RecorderCore` |
| Signing | Existing Apple Development identity, manual signing, hardened runtime on, sandbox off |

Why not `SCRecordingOutput`: it records one stream to one file. It cannot do the mixed track, the composited camera, side-by-side, or gap-free pause. One pipeline for all modes is less code than two.

Why a dedicated audio stream: a stream's audio is scoped by its video filter, so a window capture only hears that window's app. BetterCapture hit this (issue #196 "No system sound") and solved it with a separate stream. Using it in every mode removes a mode-specific branch.

## 2. Reuse research

### BetterCapture (MIT, active, macOS 15.2+): copy with attribution

| File | What to take |
|---|---|
| `BetterCapture/Service/SystemAudioStream.swift` | Almost verbatim. Full-display filter, 2x2 video, 1 fps, `excludesCurrentProcessAudio = true`, 48 kHz stereo, and a discard `.screen` output (SCK logs an error per frame without one). Add the `.microphone` output here. |
| `BetterCapture/Service/AssetWriter.swift` | Emulate the design: constant-frame-rate grid, repeat last frame across stalls, a drain loop on `requestMediaDataWhenReady`, a cap on gap filling, session started at `.zero` with a shared anchor, pause by subtracting total paused time, silence fill or trim at resume boundaries. |
| `BetterCapture/Service/SilentAudioBuffer.swift` | Pads the head of each audio track so all tracks start at zero. |
| `BetterCapture/Service/AssetWriterSettings.swift` | Codec/bitrate table shape (bits-per-pixel formula, key-frame interval 2 s, BT.709 colour properties, AAC 48 kHz). Drop the HDR branches. |
| `BetterCapture/Service/CaptureSizeCalculator+ContentFilter.swift` | Pixel size from the content filter rather than display modes; matters for the rotated display. |
| `BetterCapture/Service/PermissionService.swift` | `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `AVCaptureDevice.requestAccess`, System Settings deep links. |
| `BetterCapture/Service/AudioDeviceService.swift`, `CameraDeviceService.swift` | Mic and camera pickers. |
| `BetterCapture/View/MenuBarTimerImage.swift`, `Model/RecordingClock.swift` | Menu-bar timer (elapsed time excluding pauses). |
| `BetterCapture/Service/CaptureEngine.swift` | Stream configuration: `queueDepth = 8`, BGRA, `scalesToFit = true` for window capture, fail fast on a disconnected display. |

Pitfalls from its code and issues:
- `minimumFrameInterval` is a floor, not a cadence; raw timestamps jitter and stall.
- Non-monotonic timestamps permanently fail the writer.
- The writer lays audio back to back and ignores timestamp gaps, so gaps must be filled explicitly.
- Open issue #208: mic track stops when the input device changes mid-recording.
- Open issue #209: users want mic gain / auto level (supports the normalize feature).

### QuickRecorder (AGPL-3.0): ideas only, copy nothing

- `CameraOverlayer.swift`: floating camera window on `AVCaptureVideoPreviewLayer` (same idea as bubble mode).
- `RecordEngine.swift`: pause via a running `timeOffset`.
- Issues: #74 pause corrupted video; #87 pause didn't pause all streams together → one shared output timeline. #118 / #134 accelerated / chipmunk mic → never assume the mic is 48 kHz. #295 menu-bar controls unresponsive on macOS 27 → test the menu on 27 in M0.

### Azayaka (no license file = all rights reserved): ideas only

- `Recording.swift` uses `SCRecordingOutput` + `captureMicrophone` on macOS 15.
- Issues: #16 AirPods mic not working, #35 request for separate tracks.

## 3. Architecture

```
Displays/Window --SCStream(video only)--> LatestFrameStore --+
Camera ----------AVCaptureSession-------> LatestFrameStore --+--> FrameClock tick --> Compositor (CI) --> VideoTrack
                                                              |                                             |
Audio SCStream --.audio-------> TimelineAligner(sys) --+------+--> Mixer --> Mix track (enabled)            v
                --.microphone-> TimelineAligner(mic) --+--------------> System track, Mic track --> AVAssetWriter(s)
```

### 3.1 Timeline

- `anchor` = host time at which recording starts (after every selected video source delivered its first complete frame, 3 s timeout).
- `outputTime(host) = host - anchor - totalPaused`.
- Video frame `k` is written at PTS `k / fps` (timescale 600). Audio is written by sample count at 48 kHz.
- Capture timestamps are used only to place data on the output timeline.

### 3.2 Video path

- Each `SCStreamOutput` callback keeps only `.complete` frames and stores the pixel buffer in a lock-protected `LatestFrameStore`.
- `FrameClock` is a strict `DispatchSourceTimer`; on each fire it computes the frame index from host time, so late ticks are filled by repeats (cap 2 s).
- Each tick, per output file: take the latest frame per source, composite, append. A static screen repeats automatically; two displays stay in sync within one frame interval.
- Fast path: single source, no overlay, no scaling → append the source buffer directly.
- Back-pressure: if the video input is not ready, skip that index. Never block capture queues.
- A/V offset: apply one constant `avOffsetMs` to the audio timeline (start at 40 ms, calibrate in M1).

### 3.3 Audio path

- System audio: 48 kHz stereo float from SCK.
- Mic: convert every buffer with `AVAudioConverter` built from that buffer's format; rebuild when the format changes.
- `TimelineAligner` per source → continuous 48 kHz stream from the anchor: head padded with silence, pre-anchor audio trimmed; gap/overlap > 20 ms vs timestamp corrected by inserting silence or dropping samples (also absorbs clock drift).
- `Mixer`: sums the two aligned streams in blocks, mic upmixed to stereo, peak limiter at -1 dBFS. A source > 200 ms behind is treated as silence so the mix never stalls.
- Three writer inputs, AAC 48 kHz: Mix stereo 160 kbps, System stereo 160 kbps, Mic mono 96 kbps. PCM for ProRes MOV.
- Mix is the first audio track; System and Mic written with `marksOutputTrackAsEnabled = false` and titles "Mix", "System", "Microphone".
- Mic source: SCK microphone first; fall back to `AVCaptureAudioDataOutput` behind the same `MicSource` protocol if M1 testing shows device problems.
- Echo on speakers: not solved in v1.

### 3.4 Pause and resume

- Pause records host time; streams keep running. While paused, ticks append nothing and aligners discard input.
- Resume adds the paused span to `totalPaused`; video continues at the next frame index; audio cut/continue at exact samples.
- All tracks and output files share the same `totalPaused`.

### 3.5 Outputs for two displays

| Mode | Writers | Notes |
|---|---|---|
| Combined | 1 | SCK delivers each display already scaled to its slot |
| Separate | 2 | Same anchor and frame grid; all three audio tracks in both files |
| Both | 3 | Capture native, scale in Core Image for the combined file |

Combined layout: order by `NSScreen.frame.minX`; common height H (default 2160; settings 2160/1440/1080); widths rounded to even. With the current displays: 3840x2160 + 1216x2160 = 5056x2160. H.264 is limited to ~4096 wide, so with H.264 the canvas is scaled down to fit.

### 3.6 Camera overlay

Composited mode: camera 1280x720 @30, mirrored by default; overlay size = 18% of output height, margin 2%; round = centre-crop square + circle mask, rectangle = 16:9 with rounded corners; shape/corner/on-off in a lock-protected `OverlayConfig` read every tick; off stops the camera session; in combined mode the corner is relative to the whole canvas.

Bubble mode: borderless non-activating floating `NSPanel` on all Spaces with an `AVCaptureVideoPreviewLayer` and shape mask; filter `SCContentFilter(display:excludingApplications:[ourApp], exceptingWindows:[bubbleWindow])`; corner mapping: one display → its corner; two displays → TL/BL leftmost, TR/BR rightmost. Window mode always uses composited overlay.

### 3.7 Window mode

Own submenu from `SCShareableContent` (on-screen, layer 0, titled, > 100 px, "App: Title"); `desktopIndependentWindow`, `scalesToFit = true`; canvas fixed at start, aspect-fit on resize; window closed → finalize and notify.

### 3.8 Robustness

Prevent display sleep while recording; display unplugged / stream error → stop and finalize, notify; stop below 2 GB free disk; stop order: freeze stop time, flush audio, finish inputs, finish writing, stop streams.

## 4. Resolution, memory, CPU, file size (estimates)

- Pixel size from `SCContentFilter.contentRect` × `pointPixelScale`. Verify on the rotated display in M1.
- Memory: ~0.5 GB single display, up to ~1 GB in "both" mode; switch to `420v` if needed.
- Core Image compositing should be a few ms/frame on M3.

| Output | Bitrate ceiling | Per hour |
|---|---|---|
| HEVC 3840x2160 @30 | ~10 Mbps | up to ~4.5 GB |
| HEVC combined 5056x2160 @30 | ~13 Mbps | up to ~6 GB |
| H.264 3840x2160 @30 | ~17 Mbps | up to ~8 GB |
| ProRes 422 4K @30 | ~500 Mbps | ~220 GB (warn in settings) |
| Audio, three AAC tracks | 416 kbps | ~190 MB |

## 5. Project layout and build

XcodeGen (`project.yml`, generated `.xcodeproj` git-ignored) + local Swift package `RecorderCore` for pure, unit-tested logic.

```
mrecorder/
  project.yml
  Makefile                      # gen, build, install (~/Applications), run, test
  App/
    Info.plist, mRecorder.entitlements
    AppDelegate.swift, StatusItemController.swift
    Settings/  Onboarding/  Capture/  Pipeline/  Bubble/
  Packages/RecorderCore/
    Sources/RecorderCore/ (Timeline, CanvasLayout, OverlayGeometry, TimelineAligner, Mixer, LoudnessMeter)
    Tests/RecorderCoreTests/
```

- Info.plist: `LSUIElement = YES`, mic / camera / screen-capture usage descriptions.
- Entitlements: hardened runtime, `device.audio-input`, `device.camera`, no sandbox.
- Signing: Screen Recording permission is tied to the code-signing identity → always sign with the same Apple Development certificate and run the copy installed at `~/Applications/mRecorder.app`. M0 tests that the grant survives a rebuild.
- macOS 15 needed for `captureMicrophone`; nothing needs 26/27. macOS 15+ periodically re-asks for screen-recording consent; expected.

## 6. Menu and settings

Idle menu: Start Recording; Source (displays, Both Displays, Window submenu); Two-display Output (Combined / Separate / Both); Camera (On/Off, Shape, Corner, Device); Microphone (Off, devices); Settings…; Open Recordings Folder; Quit.

Recording menu: Pause/Resume; Stop; camera items stay enabled; source/output disabled. Status item shows elapsed time, paused state, "Finalizing".

Settings (SwiftUI, `UserDefaults`): container/codec, frame rate, combined height, save folder (default `~/Movies/Recordings`), camera mode (composited / bubble), overlay size, mirror, show cursor, normalize audio, A/V offset.

## 7. Milestones

**M0: skeleton, signing, permissions.** Builds with `xcodebuild`; no Dock icon; all three permissions grantable; Screen Recording grant survives a rebuild; menu responds on macOS 27.

**M1: single display + system audio + mic to file (HEVC MP4).** Accept: `ffprobe` shows constant 30 fps video + three audio tracks, only the first enabled; both displays record with correct size/orientation; static screen 60 s → 60 s file; remote voice (Chrome / Zoom / Jitsi) in System track, Mic only local voice on headphones; flash/beep sync within 50 ms; 30-min drift < 20 ms; AirPods switch without pitch change.

**M2: pause/resume.** 10 s + pause 20 s + 10 s → 20 s on all tracks; no click at join; sync holds after three pauses.

**M3: composited camera overlay.** Not visible on screen, present in file; corners/shapes/on-off change live; clap sync ~100 ms; camera light off when toggled off; camera picker incl. Continuity Camera.

**M4: two displays.** Combined / separate / both; arrangement order; identical timestamps across separate files; "both" mode < 1% skipped frames over 10 min.

**M5: window mode.** Window recording still has all system audio; resize/move handled; closing finalizes.

**M6: bubble mode.** Bubble in file, our UI never; live corner moves; two-display corner mapping; visible over full-screen apps.

**M7: settings and polish.** Persisted settings, H.264 / ProRes, save folder, frame rate, combined height, hot-plug, disk guard, sleep prevention, notifications with "Show in Finder".

**M8: normalize audio + crash-safe finalize.** See §8.

## 8. Normalize audio (optional, off by default)

Post-stop pass, not a live AGC:
1. Decode System and Mic tracks.
2. Measure integrated loudness of each (EBU R128 / BS.1770, ~100 lines with `vDSP`, unit-tested against `ffmpeg -af ebur128`).
3. Static gain per source to ~-18 LUFS (cap +20 dB, skip near-silent sources).
4. Re-mix, final gain to -16 LUFS, limit to -1 dBTP, encode AAC.
5. New file: video copied, System and Mic copied untouched, Mix replaced; swap in on success.

Scope: the mixed track only. Cost estimate: 15–40 s per hour of recording on M3, in the background.

Crash safety in the same pass: record to fragmented MOV (`movieFragmentInterval`), remux to MP4 on finalize. Verify the remux keeps track enabled flags; otherwise use `AVAssetReader`/`AVAssetWriter` copy.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Permission resets on rebuild | Fixed signing identity and install path; tested in M0 |
| Mic/system drift, Bluetooth rate changes | Per-buffer conversion, aligner with 20 ms correction; drift test in M1 |
| Mic track dies on device change | Rebuild converter; restart audio stream or switch mic source |
| Wrong pixel size on rotated display | Size from content filter; M1 check |
| "Both" mode overloads encoder | Measure in M4; 4:2:0 capture or 30 fps cap |
| Players play all audio tracks | Disabled flag on System/Mic; verify in M1 and after remux in M8 |
| A/V offset from latest-frame sampling | One calibrated constant |
| Echo on speakers | Headphones recommended |
| Bubble not captured / own windows captured | App exclusion + bubble exception; M6 |
| Crash loses a long call | Fragmented MOV + remux (M8) |

## 10. Out of scope for v1

HDR, area selection, global hotkeys, floating control bar, draggable bubble, echo cancellation, auto-update, notarization.

## 11. Open questions (defaults used until answered)

1. Camera in separate-files mode (composited): which file gets it? Default: the display the chosen corner belongs to.
2. Combined height 2160 (portrait screen shrunk to ~64%) OK?
3. Headphones or speakers on calls? (speakers → echo becomes a feature)
4. Separate files: all three audio tracks in both files? Default: yes.
5. Normalize default: off.
6. Crash-safe MOV + remux: OK that stop takes a few extra seconds per GB?
7. Frame rate default: 30 fps.
8. Bubble: corner-snapped only, or draggable too? Default: snapped.
9. Signing: existing Apple Development certificate. Default: yes.

## 12. Added after M1 (2026-11-25)

Implemented:
- Settings window: save folder, maximum resolution (Original / 1440p / 1080p / 720p, caps the shorter side; ScreenCaptureKit scales on the GPU), file naming.
- File naming: `YYYY-MM-DD NNN` (per-day counter), or the same plus a title from the local Claude CLI (`claude -p --model sonnet`).
- After-recording pipeline (`App/PostProcess/`), one recording at a time, in the background, each step switchable:
  1. Transcription with local `mlx_whisper` (`whisper-large-v3-turbo`, language auto-detected).
  2. Subtitles: `.srt` next to the video, plus an embedded `mov_text` track (ffmpeg remux; audio track flags preserved).
  3. Summary `.md` via Claude CLI with selectable sections: short summary, decisions and action items, chapters with timestamps, full transcript.
  4. Rename video, `.srt` and `.md` with the title.
- With no speech, the title comes from three screenshots that Claude views with its Read tool.
- URL scheme `mrecorder://start|stop|toggle`.

## 13. Status (2026-11-25)

- M0, M1: done. Your own LG-screen and voice test is still pending.
- M2 pause/resume: done. The timeline keeps every pause interval, so late audio from before a pause still maps correctly. Tested with a 5 s pause: the file is shorter by exactly the paused time.
- M3 camera overlay (composited): done. Camera menu: on/off, Circle/Rectangle, 4 corners, S/M/L size, mirror, device (incl. Continuity Camera). All of these work live during recording. The camera runs only while the overlay is on.
  - The C920 takes ~2 s to deliver its first frame, so the overlay appears ~2 s after start.
- URL commands: `mrecorder://start|stop|toggle|pause|resume`, `mrecorder://camera?on=1&shape=circle|rectangle&corner=topLeft|topRight|bottomLeft|bottomRight&size=0.22`.
- App icon: `Tools/make-icon.swift`, regenerate with `make icon`.
- Next: M4 (two displays: combined / separate / both), M5 (window), M6 (bubble mode).
- M4 two displays: done. Source menu → All Screens as one combined video / separate videos / both.
  - Combined layout: left-to-right by screen position, scaled to a common height (2160, or the resolution cap). Your screens give 5054×2160.
  - Separate files are named `… (PHL 328E1).mp4` / `… (LG ULTRAFINE).mp4` and are frame-identical in timing.
  - Camera: in a combined video it uses the corner of the whole canvas. In separate files it goes to the file of the screen that owns the corner (left corners → left screen).
  - Post-processing transcribes once, embeds subtitles into every file and renames all files together.
- M5 window mode: done. Source → Window ▸ lists open windows.
  - System audio is still the whole system. The camera is composited onto the window video.
  - A resized window stays fully visible (aspect kept). Cosmetic: it is top-aligned, not centred.
  - Closing the window stops and saves quietly.
- URL: `mrecorder://source?mode=display&id=N | mode=all&output=combined|separate|both | mode=window&app=Name`.
- M6 bubble mode: done. Settings → Camera appears: "Only in the video" or "As a floating bubble on screen".
  - The bubble is a click-through panel above all windows and Spaces (incl. full screen). It is snapped to the chosen corner of the screen's visible area.
  - It is captured because the filter excludes this app except the bubble window. The panel stays on screen (transparent) while the camera is off, so it can be switched on mid-recording.
  - Two screens: left corners → leftmost screen, right corners → rightmost.
  - Window recordings fall back to the composited camera.
- M7 settings and polish: done.
  - Format: HEVC MP4 / H.264 MP4 (canvas scaled to ≤4096) / ProRes 422 MOV with 24-bit PCM audio.
  - Settings: 30/60 fps, combined height 2160/1440/1080, show pointer.
  - Disk guard: won't start under 2 GB free; stops under 1 GB.
  - "Recording saved" notification; clicking it reveals the file in Finder.
  - Window mode now centres a resized window (content area derived from the window's aspect ratio).
  - `mrecorder://settings`.
- M8 normalize audio: done. Settings → "Even out the volume" (off by default). Post-stop pass: BS.1770 meter in RecorderCore (`LoudnessAnalyzer`, one pass, exact mix loudness from per-100 ms energies + cross terms, unit-tested against reference sines; matches `ffmpeg ebur128` to 0.1 LU on real files), `NormalizePlan` (each source to -18 LUFS, ±20 dB cap, sources under -50 LUFS left alone; mix to -16 LUFS; -1 dBFS limiter). `AudioNormalizer` rebuilds only the Mix track (AAC or 24-bit PCM like the original); video, System, Mic copied untouched, enabled flags and alternate group kept, sync verified (lag 0). Runs before transcription. ~0.1 s per 15 s of HEVC; ~1 s for 780 MB of ProRes.
- M8 crash safety: done. Writers use `movieFragmentInterval` 5 s; a normal finish yields an ordinary (non-fragmented) file, so no remux is needed. In-progress files are journaled in UserDefaults; at the next launch they are recovered (verified with kill -9: 10 s of a 14.5 s recording kept), post-processed, and announced as "Recording recovered after an unexpected quit". Quitting or logging out while recording stops and saves first.
- Open: microphone hot-swap mid-recording is untested. With the MacBook lid closed the built-in mic records silence (hardware), so pick another mic in clamshell mode. Post-processing that is interrupted by quitting is not resumed.

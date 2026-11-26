# mRecorder

A small menu-bar screen recorder for macOS 15+, made for recording calls and demos.

- Record one screen, all screens (one combined video, separate files, or both), or a single window.
- System audio (every app, including the other people on Zoom / Meet / Jitsi calls) plus your microphone:
  a mixed track that players use, and separate System and Microphone tracks for editing.
- Camera overlay, round or rectangular, in any corner: drawn into the video, or as a floating bubble on screen.
  Shape, corner, size and on/off can change during recording.
- Pause / resume, HEVC / H.264 / ProRes, 30 or 60 fps, resolution cap to save disk space.
- Crash-safe: files are written in 5-second fragments and recovered at the next launch.
- Optional after each recording:
  - on your Mac: even out the volume (EBU R128 loudness levelling of the mixed track),
  - on your Mac: subtitles with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (`.srt` + embedded track via ffmpeg),
  - off by default, because it sends the transcript to Claude with your account: a summary and a descriptive
    file name with the [Claude Code](https://claude.com/claude-code) CLI.
- **Start Recording…** opens a setup window with your last choices preselected: pick a screen (shown in
  its real arrangement with a live preview), all screens, or a window (live previews with titles); turn system
  audio, the microphone and the camera on or off, place the camera, and choose the folder. Return starts;
  double-clicking a preview starts right away.
- Global keyboard shortcuts, changeable in Configuration → Shortcuts: ⌃⌥⌘R start (press again in the setup
  window to start), ⌃⌥⌘P pause / resume, ⌃⌥⌘S stop, ⌃⌥⌘M mute / unmute the microphone, ⌃⌥⌘C camera on / off.
- Scriptable: `mrecorder://start`, `new` (setup window), `stop`, `toggle`, `pause`, `resume`, `mute`, `settings`,
  `camera?on=1&shape=circle&corner=bottomRight`, `source?mode=all&output=combined`.
  Since any web page or app can open such a link, links only open the setup window until you turn on
  Configuration → General → Automation and confirm once after each launch; then `start` records right away
  and the other commands work.

## Install

1. Download `mRecorder-x.y.z.dmg` from [Releases](https://github.com/yevgenmalafeyev/mrecorder/releases/latest),
   open it and drag **mRecorder** to **Applications**. Requires macOS 15 or later (Apple Silicon or Intel).
2. The app is signed but not notarized by Apple, so the first launch is blocked with
   *"Apple could not verify mRecorder…"*. Click **Done**, open **System Settings → Privacy & Security**,
   scroll down and click **Open Anyway** next to mRecorder, then confirm. This is needed only once.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/mRecorder.app`.)
3. The icon appears in the menu bar (there is no Dock icon). Allow Screen Recording, Microphone and Camera
   when asked; after granting Screen Recording, quit and reopen the app.

Optional extras for transcription and summaries are listed under [Build](#build) → optional tools;
transcription needs Apple Silicon.

## Build

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an Apple Development signing identity
(a stable identity keeps the Screen Recording permission across rebuilds).

```sh
make run      # generate, build, sign, install to ~/Applications and launch
make test     # unit tests of the timing, audio and layout logic
```

Optional tools, found in `~/.local/bin` or `/opt/homebrew/bin`: `mlx_whisper` (`pipx install mlx-whisper`),
`ffmpeg` (`brew install ffmpeg`), `claude` (Claude Code CLI). They are run as separate programs and are not
part of this project. Summaries send the transcript to Claude using your own Claude account.

## Credits

- Design informed by [BetterCapture](https://github.com/jsattler/BetterCapture) (MIT), notably the dedicated
  system-audio stream and the constant-frame-rate writer.
- K-weighting filter coefficients as published in [libebur128](https://github.com/jiixyj/libebur128) (MIT),
  following ITU-R BS.1770.

See [PLAN.md](PLAN.md) for the design notes. Licensed under the [MIT License](LICENSE).

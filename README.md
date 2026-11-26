# MacRecorder

A small menu-bar screen recorder for macOS 15+, made for recording calls and demos.

- Record one screen, all screens (one combined video, separate files, or both), or a single window.
- System audio (every app, including the other people on Zoom / Meet / Jitsi calls) plus your microphone:
  a mixed track that players use, and separate System and Microphone tracks for editing.
- Camera overlay, round or rectangular, in any corner: drawn into the video, or as a floating bubble on screen.
  Shape, corner, size and on/off can change during recording.
- Pause / resume, HEVC / H.264 / ProRes, 30 or 60 fps, resolution cap to save disk space.
- Crash-safe: files are written in 5-second fragments and recovered at the next launch.
- Optional after each recording, all on your Mac:
  - even out the volume (EBU R128 loudness levelling of the mixed track),
  - subtitles with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (`.srt` + embedded track via ffmpeg),
  - a summary and a descriptive file name with the [Claude Code](https://claude.com/claude-code) CLI.
- Scriptable: `macrecorder://start`, `stop`, `toggle`, `pause`, `resume`, `settings`,
  `camera?on=1&shape=circle&corner=bottomRight`, `source?mode=all&output=combined`.

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

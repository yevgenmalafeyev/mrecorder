import AppKit
import SwiftUI

/// Settings window: save folder, resolution, naming, and after-recording processing.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "mRecorder Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Settings.Keys.saveFolder) private var saveFolder = Settings.defaultSaveFolder.path
    @AppStorage(Settings.Keys.maxShortSide) private var maxShortSide = 0
    @AppStorage(Settings.Keys.namingMode) private var namingMode = NamingMode.dateCounter.rawValue
    @AppStorage(Settings.Keys.normalizeAudio) private var normalizeAudio = false
    @AppStorage(Settings.Keys.transcribe) private var transcribe = true
    @AppStorage(Settings.Keys.embedSubtitles) private var embedSubtitles = true
    @AppStorage(Settings.Keys.summary) private var summary = true
    @AppStorage(Settings.Keys.summaryShort) private var summaryShort = true
    @AppStorage(Settings.Keys.summaryActions) private var summaryActions = true
    @AppStorage(Settings.Keys.summaryChapters) private var summaryChapters = true
    @AppStorage(Settings.Keys.summaryTranscript) private var summaryTranscript = true
    @AppStorage(Settings.Keys.videoFormat) private var videoFormat = VideoFormat.hevc.rawValue
    @AppStorage(Settings.Keys.fps) private var fps = 30
    @AppStorage(Settings.Keys.showCursor) private var showCursor = true
    @AppStorage(Settings.Keys.combinedHeight) private var combinedHeight = 2160
    @AppStorage(Settings.Keys.cameraMode) private var cameraMode = CameraMode.composited.rawValue

    private let hasClaude = Tools.claude != nil
    private let hasWhisper = Tools.whisper != nil
    private let hasFFmpeg = Tools.ffmpeg != nil

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text((saveFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Maximum resolution", selection: $maxShortSide) {
                    Text("Original").tag(0)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Text("Caps the shorter side of the video. 1080p uses about a quarter of the disk space of 4K; good for calls.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("File name", selection: $namingMode) {
                    Text("Date and number (2026-11-25 001)").tag(NamingMode.dateCounter.rawValue)
                    Text("Date, number and title from Claude").tag(NamingMode.claude.rawValue)
                        .disabled(!hasClaude)
                }
                if !hasClaude {
                    missing("Claude CLI not found, so titles are not available.")
                }
            }

            Section("Recording") {
                Picker("Format", selection: $videoFormat) {
                    Text("MP4, HEVC (small files)").tag(VideoFormat.hevc.rawValue)
                    Text("MP4, H.264 (plays everywhere)").tag(VideoFormat.h264.rawValue)
                    Text("MOV, ProRes 422 (for editing)").tag(VideoFormat.prores.rawValue)
                }
                if videoFormat == VideoFormat.prores.rawValue {
                    Text("ProRes is very large: about 200 GB per hour at 4K. Use only for short clips you will edit.")
                        .font(.caption).foregroundStyle(.orange)
                } else if videoFormat == VideoFormat.h264.rawValue {
                    Text("H.264 is limited to 4096 pixels wide, so a combined two-screen video is scaled down to fit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps (smoother scrolling, larger files)").tag(60)
                }
                Picker("Combined video height", selection: $combinedHeight) {
                    Text("2160 (4K)").tag(2160)
                    Text("1440").tag(1440)
                    Text("1080").tag(1080)
                }
                Text("Used when all screens are recorded into one video.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show mouse pointer", isOn: $showCursor)
            }

            Section("Camera") {
                Picker("Camera appears", selection: $cameraMode) {
                    Text("Only in the video").tag(CameraMode.composited.rawValue)
                    Text("As a floating bubble on screen").tag(CameraMode.bubble.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(cameraMode == CameraMode.bubble.rawValue
                     ? "You see yourself in a bubble while recording, and it is recorded with the screen. Window recordings always put the camera into the video."
                     : "The camera is drawn into the recording only; nothing covers your screen.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shape, corner, size and on/off are in the menu and work during recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("After recording") {
                Toggle("Even out the volume (EBU R128 loudness levelling)", isOn: $normalizeAudio)
                Text("Brings quiet and loud voices to a similar level in the played track, so a quiet call or a distant mic is easier to hear. The separate System and Microphone tracks stay untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Transcribe speech (on this Mac, auto-detects language)", isOn: $transcribe)
                    .disabled(!hasWhisper)
                if !hasWhisper { missing("mlx_whisper not found. Install with: pipx install mlx-whisper") }
                Toggle("Embed subtitles in the video (also saves an .srt file)", isOn: $embedSubtitles)
                    .disabled(!transcribe || !hasFFmpeg)
                    .padding(.leading, 16)
                if !hasFFmpeg { missing("ffmpeg not found; only the .srt file is saved. brew install ffmpeg") }

                Toggle("Write a summary file (.md) with Claude", isOn: $summary)
                    .disabled(!transcribe)
                Group {
                    Toggle("Short summary", isOn: $summaryShort)
                    Toggle("Decisions and action items", isOn: $summaryActions)
                    Toggle("Chapters with timestamps", isOn: $summaryChapters)
                    Toggle("Full transcript", isOn: $summaryTranscript)
                }
                .disabled(!transcribe || !summary)
                .padding(.leading, 16)
                Text("Summaries and titles are made by your local Claude CLI, which sends the transcript (or, with no speech, a few screenshots) to Claude using your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }

    private func missing(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveFolder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}

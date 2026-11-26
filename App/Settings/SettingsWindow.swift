import AppKit
import SwiftUI

/// Settings window: save folder, resolution, naming, and after-recording processing.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "mRecorder Configuration"
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
    @AppStorage(Settings.Keys.allowURLControl) private var allowURLControl = false

    private let hasClaude = Tools.claude != nil
    private let hasWhisper = Tools.whisper != nil
    private let hasFFmpeg = Tools.ffmpeg != nil

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            recording.tabItem { Label("Recording", systemImage: "record.circle") }
            camera.tabItem { Label("Camera", systemImage: "video") }
            afterRecording.tabItem { Label("After Recording", systemImage: "wand.and.stars") }
            ShortcutsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(.top, 8)
        .frame(width: 560, height: 520)
    }

    private var general: some View {
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

            Section("Automation") {
                Toggle("Let links and other apps start, stop and change recordings", isOn: $allowURLControl)
                Text(allowURLControl
                     ? "mrecorder:// links (Raycast, Shortcuts, scripts) work fully. Any web page, message or app can open such a link, so it could start recording without you clicking anything."
                     : "mrecorder://start only opens the New Recording window, so you always confirm. Commands that stop, pause, mute or change a recording are ignored.")
                    .font(.caption).foregroundStyle(allowURLControl ? .orange : .secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var recording: some View {
        Form {
            Section("Video") {
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
        }
        .formStyle(.grouped)
    }

    private var camera: some View {
        Form {
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
                Text("On/off, shape, corner and size are chosen when you start a recording, and can be changed from the menu or with the camera shortcut while recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var afterRecording: some View {
        Form {
            Section("Audio") {
                Toggle("Even out the volume (EBU R128 loudness levelling)", isOn: $normalizeAudio)
                Text("Brings quiet and loud voices to a similar level in the played track, so a quiet call or a distant mic is easier to hear. The separate System and Microphone tracks stay untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Subtitles and summary") {
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
                Text("Summaries and titles are made by your local Claude CLI, which sends the transcript to Claude using your account. With no speech, three screenshots are sent, and only when titles from Claude are on. The CLI runs without your Claude Code settings, hooks, connectors or tools, so text in a recording cannot make it act.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tools used") {
                ForEach([("Transcription", "mlx_whisper"), ("Subtitles", "ffmpeg"), ("Summaries", "claude")], id: \.1) { label, name in
                    LabeledContent(label) {
                        Text(Tools.find(name).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "not found")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                Text("These programs run after each recording with access to the recording. Make sure they are the ones you installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

/// Global keyboard shortcuts; they work in every app.
struct ShortcutsView: View {
    @State private var version = 0

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutField(action: action, onChange: { version += 1 })
                    }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These work in every app. Click a shortcut and press new keys (with ⌘ or ⌃); Delete turns it off, Esc keeps the old one. The start shortcut opens the New Recording window; pressing it again there starts recording.")
                    Button("Restore Defaults") {
                        Settings.resetShortcuts()
                        Hotkeys.shared.register()
                        version += 1
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(version)
    }
}

private struct ShortcutField: View {
    let action: HotkeyAction
    let onChange: () -> Void
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    init(action: HotkeyAction, onChange: @escaping () -> Void) {
        self.action = action
        self.onChange = onChange
        _shortcut = State(initialValue: Settings.shortcut(for: action))
    }

    var body: some View {
        HStack(spacing: 6) {
            if !recording, Hotkeys.shared.conflicts.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Another app already uses this shortcut. Choose a different one.")
            }
            Button(action: toggleRecording) {
                Text(recording ? "Type shortcut…" : shortcut?.display ?? "None")
                    .monospaced()
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.accentColor : shortcut == nil ? .secondary : .primary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        Hotkeys.shared.unregister() // so pressing a current shortcut doesn't trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stopRecording()
            case 51, 117: // Delete, Forward Delete
                save(nil)
            default:
                guard let s = Shortcut(event: event) else { NSSound.beep(); return nil }
                save(s)
            }
            return nil
        }
    }

    private func save(_ s: Shortcut?) {
        shortcut = s
        Settings.setShortcut(s, for: action)
        stopRecording()
        onChange()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        Hotkeys.shared.register()
    }
}

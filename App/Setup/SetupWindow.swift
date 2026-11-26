import AppKit
import AVFoundation
import RecorderCore
import ScreenCaptureKit
import SwiftUI

/// The window shown before a recording: what to record, sound, camera and where to save.
/// Choices are saved and preselected next time.
/// Used from the main thread only (menu actions, shortcuts, URL commands).
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?
    private var model: SetupModel?

    var isVisible: Bool { window?.isVisible == true }

    /// `onStart` runs after the choices are saved and the window is closed.
    /// Opened from a link, Start stays off for a moment so a key press or click already under way can't start it.
    func show(fromLink: Bool = false, onStart: @escaping () -> Void) {
        MainActor.assumeIsolated {
            if let window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }
            let model = SetupModel()
            if fromLink {
                model.armed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak model] in
                    MainActor.assumeIsolated { model?.armed = true }
                }
            }
            model.onStart = { [weak self] in
                self?.close()
                // Let the window leave the screen before capture begins.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: onStart)
            }
            model.onCancel = { [weak self] in self?.close() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            w.title = "New Recording"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            self.model = model
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            model.startRefreshing()
        }
    }

    /// Starts with the choices currently shown (the start shortcut pressed while the window is open).
    func startNow() {
        MainActor.assumeIsolated { model?.start() }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model?.stopRefreshing() }
        model = nil
        window = nil
    }
}

// MARK: - Model

@MainActor
final class SetupModel: ObservableObject {
    enum Kind: String { case screen, window }

    struct DisplayItem: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        /// Global position in points (top-left origin), for drawing the arrangement.
        let bounds: CGRect
        let pixels: CGSize
        var thumbnail: CGImage?
    }

    struct WindowItem: Identifiable {
        let id: CGWindowID
        let app: String
        let title: String
        let icon: NSImage?
        let size: CGSize
        var thumbnail: CGImage?
        var label: String { title.isEmpty ? app : "\(app) — \(title)" }
    }

    @Published var kind: Kind
    @Published var displays: [DisplayItem] = []
    @Published var selectedDisplay: CGDirectDisplayID
    @Published var allScreens: Bool
    @Published var multiOutput: MultiDisplayOutput
    @Published var windows: [WindowItem] = []
    @Published var windowsLoaded = false
    @Published var selectedWindow: CGWindowID?

    @Published var micID: String // "" = off
    @Published var systemAudio: Bool
    let microphones: [(id: String, name: String)]

    @Published var overlay: OverlayConfig
    @Published var cameraID: String
    let cameras: [(id: String, name: String)]

    @Published var saveFolder: URL
    @Published var screenGranted = Permissions.screenGranted
    /// False for a moment after a link opened the window; Start is off meanwhile.
    @Published var armed = true

    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    private var refreshTask: Task<Void, Never>?

    init() {
        let mode = Settings.sourceMode
        kind = mode == "window" ? .window : .screen
        selectedDisplay = Settings.displayID == 0 ? CGMainDisplayID() : Settings.displayID
        allScreens = mode == "all"
        multiOutput = Settings.multiOutput
        selectedWindow = Settings.selectedWindow?.id

        microphones = Devices.microphones().map { ($0.uniqueID, $0.localizedName) }
        micID = Devices.selectedMicrophone()?.uniqueID ?? ""
        systemAudio = Settings.systemAudio

        var ov = Settings.overlay
        if Permissions.cameraStatus != .authorized { ov.enabled = false }
        overlay = ov
        cameras = Devices.cameras().map { ($0.uniqueID, $0.localizedName) }
        cameraID = Devices.camera(id: Settings.cameraDeviceID)?.uniqueID ?? ""

        saveFolder = Settings.saveFolder
        displays = Devices.displaysLeftToRight().map { id in
            DisplayItem(id: id, name: Devices.displayName(for: id), bounds: CGDisplayBounds(id),
                        pixels: CGDisplayCopyDisplayMode(id).map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
                            ?? CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)))
        }
        if !displays.contains(where: { $0.id == selectedDisplay }) { selectedDisplay = CGMainDisplayID() }
        if displays.count < 2 { allScreens = false }
    }

    var canStart: Bool {
        guard screenGranted, armed else { return false }
        switch kind {
        case .screen: return true
        case .window: return selectedWindow.map { id in windows.contains { $0.id == id } } ?? false
        }
    }

    var freeSpaceText: String? {
        guard let free = AppDelegate.freeSpace(at: existingAncestor(of: saveFolder)) else { return nil }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
    }

    private func existingAncestor(of url: URL) -> URL {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        return u
    }

    // MARK: Previews

    func startRefreshing() {
        refreshTask = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(includeWindows: round % 2 == 0)
                round += 1
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Updates screen previews every round and the window list with its previews every other round.
    private func refresh(includeWindows: Bool) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            screenGranted = Permissions.screenGranted
            windowsLoaded = true
            return
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        for d in content.displays {
            guard let i = displays.firstIndex(where: { $0.id == d.displayID }) else { continue }
            let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            if let img = await Self.snapshot(filter, size: CGSize(width: d.width, height: d.height), maxWidth: 960) {
                displays[i].thumbnail = img
            }
        }
        guard includeWindows else { return }

        // Front-to-back order from the window server; ScreenCaptureKit for the images.
        let order = Devices.windows().map(\.id)
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let found: [SCWindow] = order.compactMap { byID[$0] }
        let previous = Dictionary(windows.map { ($0.id, $0.thumbnail) }, uniquingKeysWith: { a, _ in a })
        var items = found.map { w in
            let app = w.owningApplication
            return WindowItem(
                id: w.windowID, app: app?.applicationName ?? "Window", title: w.title ?? "",
                icon: app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon },
                size: w.frame.size, thumbnail: previous[w.windowID] ?? nil)
        }
        windows = items
        windowsLoaded = true
        // Preselect the frontmost window (usually the one to record) unless a listed one is chosen.
        if !items.contains(where: { $0.id == selectedWindow }) { selectedWindow = items.first?.id }

        let shots = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for w in found.prefix(40) {
                group.addTask {
                    let img = await Self.snapshot(SCContentFilter(desktopIndependentWindow: w), size: w.frame.size, maxWidth: 560)
                    return (w.windowID, img)
                }
            }
            var out: [CGWindowID: CGImage] = [:]
            for await (id, img) in group { if let img { out[id] = img } }
            return out
        }
        for i in items.indices { if let img = shots[items[i].id] { items[i].thumbnail = img } }
        // The list may have been replaced while capturing; keep only windows still listed.
        let current = Set(windows.map(\.id))
        windows = items.filter { current.contains($0.id) }
    }

    private nonisolated static func snapshot(_ filter: SCContentFilter, size: CGSize, maxWidth: CGFloat) async -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cfg = SCStreamConfiguration()
        let w = min(maxWidth, size.width * CGFloat(filter.pointPixelScale))
        cfg.width = Int(w)
        cfg.height = Int(w * size.height / size.width)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    // MARK: Actions

    func setCamera(_ on: Bool) {
        guard on else { overlay.enabled = false; return }
        Permissions.requestCamera { [weak self] ok in self?.overlay.enabled = ok }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = existingAncestor(of: saveFolder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }

    func start() {
        guard canStart else { return }
        switch kind {
        case .screen:
            Settings.sourceMode = allScreens ? "all" : "display"
            Settings.displayID = selectedDisplay
            Settings.multiOutput = multiOutput
        case .window:
            guard let id = selectedWindow, let w = windows.first(where: { $0.id == id }) else { return }
            Settings.selectedWindow = (id, w.label)
            Settings.sourceMode = "window"
        }
        Settings.micDeviceID = micID
        Settings.systemAudio = systemAudio
        Settings.overlay = overlay
        if !cameraID.isEmpty { Settings.cameraDeviceID = cameraID }
        Settings.saveFolder = saveFolder
        onStart?()
    }

    func cancel() { onCancel?() }
}

// MARK: - Views

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.kind) {
                Label("Screen", systemImage: "display").tag(SetupModel.Kind.screen)
                Label("Window", systemImage: "macwindow").tag(SetupModel.Kind.window)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(width: 320)
            .padding(.top, 14)

            Group {
                if !model.screenGranted {
                    ContentUnavailableView("Screen Recording is not allowed",
                                           systemImage: "lock.display",
                                           description: Text("Allow mRecorder in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."))
                } else if model.kind == .screen {
                    ScreenPicker(model: model)
                } else {
                    WindowPicker(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            HStack(alignment: .top, spacing: 14) {
                AudioCard(model: model)
                CameraCard(model: model)
                SaveCard(model: model)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
            HStack {
                Text(shortcutHint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(action: model.start) {
                    Label("Start Recording", systemImage: "record.circle.fill").padding(.horizontal, 6)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.canStart)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 960, height: 720)
    }

    private var shortcutHint: String {
        let pairs: [(HotkeyAction, String)] = [(.start, "start"), (.pause, "pause"), (.stop, "stop"), (.mute, "mute"), (.camera, "camera")]
        let parts = pairs.compactMap { a, name in Settings.shortcut(for: a).map { "\($0.display) \(name)" } }
        return parts.isEmpty ? "Double-click a preview to start right away" : "Double-click a preview to start · " + parts.joined(separator: "  ")
    }
}

/// Displays drawn in their real arrangement, each with a live preview.
private struct ScreenPicker: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let union = model.displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
                let gap: CGFloat = 10
                let scale = union.isNull ? 1 : min((geo.size.width - gap * CGFloat(model.displays.count)) / union.width,
                                                   geo.size.height / union.height)
                let drawn = CGSize(width: union.width * scale, height: union.height * scale)
                let origin = CGPoint(x: (geo.size.width - drawn.width) / 2, y: (geo.size.height - drawn.height) / 2)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, d in
                        let r = CGRect(x: origin.x + (d.bounds.minX - union.minX) * scale + gap * CGFloat(index) / 2,
                                       y: origin.y + (d.bounds.minY - union.minY) * scale,
                                       width: d.bounds.width * scale - gap / 2, height: d.bounds.height * scale)
                        DisplayTile(display: d, selected: model.allScreens || model.selectedDisplay == d.id,
                                    isMain: d.id == CGMainDisplayID())
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onTapGesture(count: 2) {
                                model.allScreens = false
                                model.selectedDisplay = d.id
                                model.start()
                            }
                            .onTapGesture {
                                model.allScreens = false
                                model.selectedDisplay = d.id
                            }
                    }
                }
            }

            if model.displays.count > 1 {
                HStack(spacing: 12) {
                    Button {
                        model.allScreens.toggle()
                    } label: {
                        Label("All \(model.displays.count) Screens", systemImage: model.allScreens ? "checkmark.circle.fill" : "rectangle.split.2x1")
                            .padding(.horizontal, 8)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .tint(model.allScreens ? .accentColor : nil)

                    if model.allScreens {
                        Picker("", selection: $model.multiOutput) {
                            Text("One combined video").tag(MultiDisplayOutput.combined)
                            Text("Separate videos").tag(MultiDisplayOutput.separate)
                            Text("Both").tag(MultiDisplayOutput.both)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 400)
                    } else {
                        Text("Click a screen to record it, or record all of them.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DisplayTile: View {
    let display: SetupModel.DisplayItem
    let selected: Bool
    let isMain: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
            if let img = display.thumbnail {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "display").font(.system(size: 40)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ViewThatFits(in: .horizontal) {
                label(details: true)
                label(details: false)
            }
            .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 4 : 1))
        .opacity(selected ? 1 : 0.75)
        .contentShape(Rectangle())
        .help("Click to record this screen; double-click to start right away")
    }

    private func label(details: Bool) -> some View {
        HStack(spacing: 6) {
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            Text(display.name).fontWeight(.semibold).lineLimit(1)
            if details {
                Text("\(Int(display.pixels.width))×\(Int(display.pixels.height))\(isMain ? " · main" : "")")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

private struct WindowPicker: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        if model.windows.isEmpty {
            if model.windowsLoaded {
                ContentUnavailableView("No windows", systemImage: "macwindow",
                                       description: Text("Open the window you want to record; it appears here."))
            } else {
                ProgressView("Looking for windows…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(model.windows) { w in
                        WindowCard(window: w, selected: model.selectedWindow == w.id)
                            .onTapGesture(count: 2) {
                                model.selectedWindow = w.id
                                model.start()
                            }
                            .onTapGesture { model.selectedWindow = w.id }
                    }
                }
                .padding(4)
            }
        }
    }
}

private struct WindowCard: View {
    let window: SetupModel.WindowItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                if let img = window.thumbnail {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(0.6)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            HStack(spacing: 6) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(window.app).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            Text(window.title.isEmpty ? " " : window.title)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .help(window.label)
    }
}

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

private struct AudioCard: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        Card(title: "Sound", icon: "speaker.wave.2") {
            Toggle(isOn: $model.systemAudio) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("System audio")
                    Text("Other apps and call participants").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { !model.micID.isEmpty },
                                 set: { model.micID = $0 ? (Devices.selectedMicrophoneOrDefault()?.uniqueID ?? "") : "" })) {
                Text("Microphone")
            }
            .toggleStyle(.switch)
            .disabled(model.microphones.isEmpty)
            if !model.micID.isEmpty {
                Picker("", selection: $model.micID) {
                    ForEach(model.microphones, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
        }
    }
}

private struct CameraCard: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        Card(title: "Camera", icon: "video") {
            Toggle("Show camera in the video", isOn: Binding(get: { model.overlay.enabled }, set: { model.setCamera($0) }))
                .toggleStyle(.switch)
                .disabled(model.cameras.isEmpty)
            if model.overlay.enabled {
                HStack(alignment: .center, spacing: 12) {
                    CornerChooser(corner: $model.overlay.corner, shape: model.overlay.shape)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $model.overlay.shape) {
                            Image(systemName: "circle").tag(OverlayShape.circle)
                            Image(systemName: "rectangle").tag(OverlayShape.rectangle)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Picker("", selection: $model.overlay.size) {
                            Text("S").tag(0.16)
                            Text("M").tag(0.22)
                            Text("L").tag(0.30)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                if model.cameras.count > 1 {
                    Picker("", selection: $model.cameraID) {
                        ForEach(model.cameras, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

/// A small screen with the camera bubble in one corner; click a corner to move it there.
private struct CornerChooser: View {
    @Binding var corner: OverlayCorner
    let shape: OverlayShape

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.2))
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.6))
            VStack(spacing: 0) {
                HStack(spacing: 0) { cell(.topLeft); cell(.topRight) }
                HStack(spacing: 0) { cell(.bottomLeft); cell(.bottomRight) }
            }
        }
        .frame(width: 96, height: 60)
        .help("Click a corner to place the camera there")
    }

    private func cell(_ c: OverlayCorner) -> some View {
        let color = c == corner ? Color.accentColor : Color.secondary.opacity(0.35)
        let alignment = Alignment(horizontal: c == .topLeft || c == .bottomLeft ? .leading : .trailing,
                                  vertical: c == .topLeft || c == .topRight ? .top : .bottom)
        return Group {
            if shape == .circle {
                Circle().fill(color).frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 28, height: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(5)
        .contentShape(Rectangle())
        .onTapGesture { corner = c }
    }
}

private struct SaveCard: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        Card(title: "Save to", icon: "folder") {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.saveFolder.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.saveFolder.lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    Text((model.saveFolder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(model.saveFolder.path)
            HStack {
                Button("Change…", action: model.chooseFolder)
                if let free = model.freeSpaceText {
                    Text(free).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

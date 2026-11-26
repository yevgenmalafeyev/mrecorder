import AppKit
import AVFoundation
import RecorderCore
import ScreenCaptureKit
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var session: RecordingSession?
    private var state: State = .idle { didSet { updateStatusTitle() } }
    private var titleTimer: Timer?
    private var lastRecording: URL?
    private var terminateAfterStop = false
    /// Base names of recordings recovered at launch, to word their notification.
    private var recoveredBases: Set<String> = []
    private var sleepActivity: NSObjectProtocol?
    private var processingStatus: String?
    private let bubble = BubbleController()
    /// Displays the bubble may sit on while a bubble-mode recording runs; nil when not in bubble mode.
    private var bubbleDisplays: [CGDirectDisplayID]?
    private var diskTimer: Timer?

    enum State { case idle, starting, recording, finalizing }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusTitle()

        PostProcessor.shared.onStatus = { [weak self] text in self?.processingStatus = text }
        PostProcessor.shared.onFinished = { [weak self] url in
            guard let self else { return }
            self.lastRecording = url
            // A recovered recording may have been renamed; match it by its original base name.
            let recovered = self.recoveredBases.first { url.lastPathComponent.hasPrefix($0) }
            if let recovered { self.recoveredBases.remove(recovered) }
            self.notifySaved(url, title: recovered != nil ? "Recording recovered after an unexpected quit" : "Recording saved")
        }
        UNUserNotificationCenter.current().delegate = self
        umask(0o077) // recordings, transcripts and summaries are readable by this user only
        signal(SIGPIPE, SIG_IGN) // writing to a tool that already exited must not end the app
        Hotkeys.shared.handler = { [weak self] action in self?.handleHotkey(action) }
        Hotkeys.shared.register()

        if !Permissions.screenGranted {
            log.info("Screen Recording not granted yet")
        }
        removeStaleTempFolders()
        recoverUnfinished()
    }

    /// Work folders left behind when post-processing was interrupted by quitting.
    private func removeStaleTempFolders() {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for n in names where n.hasPrefix("mrecorder-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(n))
        }
    }

    /// Quitting (or logging out) while recording saves the recording first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .idle, .starting: return .terminateNow // nothing recorded yet
        case .recording:
            terminateAfterStop = true
            stopRecording()
            return .terminateLater
        case .finalizing:
            terminateAfterStop = true // the running stop replies when the files are complete
            return .terminateLater
        }
    }

    // MARK: - Crash recovery

    /// Files of the recording in progress are remembered until it is finalized. Recordings are written
    /// in 5-second fragments, so after a crash, force quit or power loss they play up to that point.
    private func journal(add session: RecordingSession) {
        let entry: [String: Any] = ["base": session.request.baseURL.path, "files": session.outputURLs.map(\.path)]
        UserDefaults.standard.set([entry], forKey: Settings.Keys.unfinished)
    }

    private func journalClear() {
        UserDefaults.standard.removeObject(forKey: Settings.Keys.unfinished)
    }

    private func recoverUnfinished() {
        guard let entries = UserDefaults.standard.array(forKey: Settings.Keys.unfinished) as? [[String: Any]] else { return }
        journalClear()
        for e in entries {
            guard let base = e["base"] as? String, let files = e["files"] as? [String] else { continue }
            // Only recordings this app writes: in the save folder, named after the recording, .mp4 or .mov.
            let folder = Settings.saveFolder.standardizedFileURL.path
            let baseURL = URL(fileURLWithPath: base).standardizedFileURL
            guard baseURL.deletingLastPathComponent().path == folder else {
                log.error("Ignoring unfinished recording outside the save folder")
                continue
            }
            let urls = files.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter {
                $0.deletingLastPathComponent().path == folder
                    && $0.lastPathComponent.hasPrefix(baseURL.lastPathComponent)
                    && ["mp4", "mov"].contains($0.pathExtension.lowercased())
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true // not a link
            }
            Task { @MainActor in
                var playable: [URL] = []
                for u in urls {
                    let d = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 0
                    if d > 0 { playable.append(u) } else { log.error("Unfinished recording \(u.lastPathComponent, privacy: .public) has no playable data") }
                }
                guard !playable.isEmpty else { return }
                log.notice("Recovered unfinished recording: \(playable.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
                lastRecording = playable[0]
                let options = PostProcessor.Options.current()
                let name = URL(fileURLWithPath: base).lastPathComponent
                recoveredBases.insert(name)
                Task.detached { await PostProcessor.shared.process(playable, baseName: name, options: options) }
            }
        }
    }

    /// mrecorder://start|new|stop|toggle|pause|resume|mute|settings|camera?on=1&shape=&corner=&size=|source?…
    /// (Raycast, Shortcuts, scripts).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "mrecorder" {
            let command = url.host ?? ""
            // Any web page or app can open these links. Unless the user allowed link control, a link can only
            // open the New Recording window or Configuration, never record or change a recording by itself.
            let needsControl = !["new", "settings"].contains(command)
            let allowed = needsControl && linkControlAllowed()
            if !allowed, !["start", "new", "toggle", "settings"].contains(command) {
                log.notice("Ignored link command \(command, privacy: .private): link control is off in Configuration")
                continue
            }
            switch command {
            case "start": allowed ? startRecording() : openSetup(fromLink: true)
            case "new": openSetup(fromLink: true)
            case "mute": toggleMute()
            case "stop": stopRecording()
            case "toggle":
                if state == .idle { allowed ? startRecording() : openSetup(fromLink: true) } else if allowed { stopRecording() }
            case "source":
                // mrecorder://source?mode=display&id=1 | mode=all&output=combined|separate|both | mode=window&app=Safari
                guard state == .idle else { break }
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
                switch v("mode") {
                case "all":
                    Settings.sourceMode = "all"
                    if let o = v("output").flatMap(MultiDisplayOutput.init(rawValue:)) { Settings.multiOutput = o }
                case "window":
                    let app = v("app") ?? ""
                    if let w = Devices.windows().first(where: { $0.app.localizedCaseInsensitiveContains(app) }) {
                        Settings.selectedWindow = (w.id, w.label)
                        Settings.sourceMode = "window"
                    } else {
                        log.error("No window found for app \(app, privacy: .private)")
                    }
                default:
                    Settings.sourceMode = "display"
                    if let id = v("id").flatMap(UInt32.init) { Settings.displayID = id }
                }
            case "settings": openSettings()
            case "pause": if session?.isPaused == false { togglePause() }
            case "resume": if session?.isPaused == true { togglePause() }
            case "camera":
                // mrecorder://camera?on=1&shape=circle&corner=topLeft&size=0.22
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
                if let on = v("on"), (on == "1") != Settings.overlay.enabled { toggleCamera() }
                applyOverlay { ov in
                    if let s = v("shape").flatMap(OverlayShape.init(rawValue:)) { ov.shape = s }
                    if let c = v("corner").flatMap(OverlayCorner.init(rawValue:)) { ov.corner = c }
                    if let z = v("size").flatMap(Double.init), z.isFinite { ov.size = Settings.clampedCameraSize(z) }
                }
            default: log.error("Unknown link command: \(command, privacy: .private)")
            }
        }
    }

    // MARK: - Status title

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "mRecorder")
            button.title = Permissions.screenGranted ? "" : " !"
            button.contentTintColor = nil
            titleTimer?.invalidate()
            titleTimer = nil
        case .starting:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Starting")
            button.title = " …"
        case .recording:
            let paused = session?.isPaused ?? false
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                   accessibilityDescription: paused ? "Paused" : "Recording")
            button.contentTintColor = paused ? .systemOrange : .systemRed
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            refreshElapsed()
            if titleTimer == nil {
                titleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.refreshElapsed()
                }
            }
        case .finalizing:
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Saving")
            button.contentTintColor = nil
            button.title = " Saving…"
            titleTimer?.invalidate()
            titleTimer = nil
        }
    }

    private func refreshElapsed() {
        guard state == .recording, let session, session.hasStarted, let button = statusItem.button else { return }
        let text = " " + Self.format(session.elapsed)
        if session.isMicMuted, let icon = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted") {
            let s = NSMutableAttributedString(string: text + " ")
            let attachment = NSTextAttachment()
            attachment.image = icon
            s.append(NSAttributedString(attachment: attachment))
            s.addAttribute(.font, value: button.font ?? NSFont.menuBarFont(ofSize: 0), range: NSRange(location: 0, length: s.length))
            button.attributedTitle = s
        } else {
            button.title = text
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state {
        case .idle:
            menu.addItem(item("Start Recording…", #selector(showSetup), enabled: Permissions.screenGranted, shortcut: .start))
        case .starting:
            menu.addItem(item("Starting…", nil, enabled: false))
        case .recording:
            let elapsed = Self.format(session?.elapsed ?? 0)
            menu.addItem(item("Stop Recording  \(elapsed)", #selector(stopRecording), shortcut: .stop))
            menu.addItem(item(session?.isPaused == true ? "Resume" : "Pause", #selector(togglePause), shortcut: .pause))
            if session?.request.microphone != nil {
                menu.addItem(item(session?.isMicMuted == true ? "Unmute Microphone" : "Mute Microphone",
                                  #selector(toggleMute), shortcut: .mute))
            }
        case .finalizing:
            menu.addItem(item("Saving recording…", nil, enabled: false))
        }
        if let processingStatus {
            menu.addItem(item("Processing last recording: \(processingStatus)", nil, enabled: false))
        }
        menu.addItem(.separator())

        let idle = state == .idle

        // Source: one screen, all screens, or a window
        let sourceMenu = NSMenu()
        let mode = Settings.sourceMode
        let selected = Settings.displayID == 0 ? CGMainDisplayID() : Settings.displayID
        let displays = Devices.displaysLeftToRight()
        for id in displays {
            let px = CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
            let it = item("\(Devices.displayName(for: id))  (\(Int(px.width))×\(Int(px.height)))",
                          #selector(selectDisplay(_:)), enabled: idle)
            it.tag = Int(id)
            it.state = mode == "display" && id == selected ? .on : .off
            sourceMenu.addItem(it)
        }
        if displays.count > 1 {
            let all = item("All Screens", #selector(selectAllScreens), enabled: idle)
            all.state = mode == "all" ? .on : .off
            sourceMenu.addItem(all)
            for (title, value) in [("    as One Combined Video", MultiDisplayOutput.combined),
                                   ("    as Separate Videos", .separate),
                                   ("    as Combined and Separate", .both)] {
                let it = item(title, #selector(selectMultiOutput(_:)), enabled: idle)
                it.representedObject = value.rawValue
                it.state = mode == "all" && Settings.multiOutput == value ? .on : .off
                sourceMenu.addItem(it)
            }
        }
        sourceMenu.addItem(.separator())
        let windowMenu = NSMenu()
        let windows = idle ? Devices.windows() : []
        for w in windows.prefix(40) {
            let it = item(String(w.label.prefix(70)), #selector(selectWindow(_:)), enabled: idle)
            it.tag = Int(w.id)
            it.representedObject = w.label
            it.state = mode == "window" && Settings.selectedWindow?.id == w.id ? .on : .off
            windowMenu.addItem(it)
        }
        if windows.isEmpty { windowMenu.addItem(item("No windows", nil, enabled: false)) }
        let windowItem = item("Window", nil, enabled: idle)
        windowItem.submenu = windowMenu
        sourceMenu.addItem(windowItem)

        let sourceTitle: String
        switch mode {
        case "all": sourceTitle = "All Screens (\(Settings.multiOutput == .combined ? "combined" : Settings.multiOutput == .separate ? "separate" : "combined + separate"))"
        case "window": sourceTitle = "Window: " + String((Settings.selectedWindow?.title ?? "none").prefix(40))
        default: sourceTitle = Devices.displayName(for: selected)
        }
        let sourceItem = item("Record: \(sourceTitle)", nil)
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        // Microphone
        let micMenu = NSMenu()
        let currentMic = Devices.selectedMicrophone()
        let off = item("Off", #selector(selectMic(_:)), enabled: idle)
        off.representedObject = ""
        off.state = currentMic == nil ? .on : .off
        micMenu.addItem(off)
        micMenu.addItem(.separator())
        for mic in Devices.microphones() {
            let it = item(mic.localizedName, #selector(selectMic(_:)), enabled: idle)
            it.representedObject = mic.uniqueID
            it.state = mic.uniqueID == currentMic?.uniqueID ? .on : .off
            micMenu.addItem(it)
        }
        let micItem = item("Microphone: \(currentMic?.localizedName ?? "Off")", nil)
        micItem.submenu = micMenu
        menu.addItem(micItem)

        // Camera (all items work during recording too)
        menu.addItem(.separator())
        let ov = Settings.overlay
        let camOn = item(ov.enabled ? "Camera: On" : "Camera: Off", #selector(toggleCamera), shortcut: .camera)
        camOn.state = ov.enabled ? .on : .off
        menu.addItem(camOn)
        let camMenu = NSMenu()
        for (title, shape) in [("Circle", OverlayShape.circle), ("Rectangle", .rectangle)] {
            let it = item(title, #selector(selectShape(_:)))
            it.representedObject = shape.rawValue
            it.state = ov.shape == shape ? .on : .off
            camMenu.addItem(it)
        }
        camMenu.addItem(.separator())
        let corners: [(String, OverlayCorner)] = [("↖︎ Top Left", .topLeft), ("↗︎ Top Right", .topRight),
                                                  ("↙︎ Bottom Left", .bottomLeft), ("↘︎ Bottom Right", .bottomRight)]
        for (title, corner) in corners {
            let it = item(title, #selector(selectCorner(_:)))
            it.representedObject = corner.rawValue
            it.state = ov.corner == corner ? .on : .off
            camMenu.addItem(it)
        }
        camMenu.addItem(.separator())
        for (title, size) in [("Small", 0.16), ("Medium", 0.22), ("Large", 0.30)] {
            let it = item(title, #selector(selectSize(_:)))
            it.representedObject = size
            it.state = abs(ov.size - size) < 0.001 ? .on : .off
            camMenu.addItem(it)
        }
        camMenu.addItem(.separator())
        let mirror = item("Mirror", #selector(toggleMirror))
        mirror.state = ov.mirror ? .on : .off
        camMenu.addItem(mirror)
        camMenu.addItem(.separator())
        let currentCam = Devices.camera(id: Settings.cameraDeviceID)
        for cam in Devices.cameras() {
            let it = item(cam.localizedName, #selector(selectCamera(_:)))
            it.representedObject = cam.uniqueID
            it.state = cam.uniqueID == currentCam?.uniqueID ? .on : .off
            camMenu.addItem(it)
        }
        let shapeName = ov.shape == .circle ? "Circle" : "Rectangle"
        let cornerName = corners.first { $0.1 == ov.corner }?.0 ?? ""
        // Drop the arrow: everything after the first space ("↘︎ Bottom Right" -> "Bottom Right").
        let cornerText = cornerName.split(separator: " ", maxSplits: 1).last.map(String.init) ?? cornerName
        let camSettings = item("Camera Style: \(shapeName), \(cornerText)", nil)
        camSettings.submenu = camMenu
        menu.addItem(camSettings)

        // Permissions
        if !Permissions.screenGranted || Permissions.micStatus != .authorized {
            menu.addItem(.separator())
            if !Permissions.screenGranted {
                menu.addItem(item("⚠︎ Grant Screen Recording…", #selector(grantScreen)))
                menu.addItem(item("Relaunch After Granting", #selector(relaunch)))
            }
            if Permissions.micStatus != .authorized {
                menu.addItem(item("⚠︎ Grant Microphone…", #selector(grantMic)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Configuration…", #selector(openSettings), key: ","))
        menu.addItem(item("Open Recordings Folder", #selector(openFolder)))
        if lastRecording != nil {
            menu.addItem(item("Show Last Recording", #selector(showLast)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit mRecorder", #selector(quit), key: "q", enabled: state == .idle))
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true,
                      shortcut: HotkeyAction? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.isEnabled = enabled
        if let shortcut { Settings.shortcut(for: shortcut)?.apply(to: it) }
        return it
    }

    // MARK: - Shortcuts

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .start:
            guard state == .idle else { return }
            // Pressed again while the setup window is open: start with what it shows.
            SetupWindowController.shared.isVisible ? SetupWindowController.shared.startNow() : showSetup()
        case .pause: togglePause()
        case .stop: stopRecording()
        case .mute: toggleMute()
        case .camera: toggleCamera()
        }
    }

    @objc private func showSetup() { openSetup(fromLink: false) }

    private func openSetup(fromLink: Bool) {
        guard state == .idle else { return }
        SetupWindowController.shared.show(fromLink: fromLink) { [weak self] in self?.startRecording() }
    }

    /// The setting alone is not enough: any program can change this app's settings, so link control must also
    /// be confirmed by a click once per launch, which a program cannot fake.
    private var linkControlConfirmed = false
    private func linkControlAllowed() -> Bool {
        guard Settings.allowURLControl else { return false }
        if linkControlConfirmed { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow links and other apps to control recording?"
        alert.informativeText = "A link or another app asked mRecorder to start, stop or change a recording. If you allow it, such requests work without asking until mRecorder quits."
        alert.addButton(withTitle: "Don't Allow") // the default button, so Return does not approve
        alert.addButton(withTitle: "Allow")
        linkControlConfirmed = alert.runModal() == .alertSecondButtonReturn
        return linkControlConfirmed
    }

    @objc private func toggleMute() {
        guard state == .recording, let session, session.request.microphone != nil else { return }
        session.setMicMuted(!session.isMicMuted)
        refreshElapsed()
    }

    // MARK: - Actions

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        Settings.displayID = UInt32(sender.tag)
        Settings.sourceMode = "display"
    }

    @objc private func selectAllScreens() { Settings.sourceMode = "all" }

    @objc private func selectMultiOutput(_ sender: NSMenuItem) {
        Settings.multiOutput = MultiDisplayOutput(rawValue: sender.representedObject as? String ?? "") ?? .combined
        Settings.sourceMode = "all"
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        Settings.selectedWindow = (CGWindowID(sender.tag), sender.representedObject as? String ?? "Window")
        Settings.sourceMode = "window"
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String ?? ""
        Settings.micDeviceID = id
        if !id.isEmpty, Permissions.micStatus != .authorized { Permissions.requestMic { _ in } }
    }

    @objc private func togglePause() {
        guard state == .recording, let session else { return }
        session.isPaused ? session.resume() : session.pause()
        updateStatusTitle()
    }

    private func applyOverlay(_ change: (inout OverlayConfig) -> Void) {
        var ov = Settings.overlay
        change(&ov)
        Settings.overlay = ov
        if let displays = bubbleDisplays {
            bubble.update(config: ov, deviceID: Settings.cameraDeviceID, displays: displays)
        } else {
            session?.setOverlay(ov, deviceID: Settings.cameraDeviceID)
        }
    }

    @objc private func toggleCamera() {
        if !Settings.overlay.enabled, Permissions.cameraStatus != .authorized {
            Permissions.requestCamera { [weak self] ok in
                if ok { self?.applyOverlay { $0.enabled = true } }
            }
            return
        }
        applyOverlay { $0.enabled.toggle() }
    }

    @objc private func selectShape(_ sender: NSMenuItem) {
        applyOverlay { $0.shape = OverlayShape(rawValue: sender.representedObject as? String ?? "") ?? .circle }
    }

    @objc private func selectCorner(_ sender: NSMenuItem) {
        applyOverlay { $0.corner = OverlayCorner(rawValue: sender.representedObject as? String ?? "") ?? .bottomRight }
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        applyOverlay { $0.size = sender.representedObject as? Double ?? 0.22 }
    }

    @objc private func toggleMirror() { applyOverlay { $0.mirror.toggle() } }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        Settings.cameraDeviceID = sender.representedObject as? String
        applyOverlay { _ in }
    }

    @objc private func grantScreen() { Permissions.requestScreen() }
    @objc private func grantMic() { Permissions.requestMic { _ in } }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is an argument, never shell code; fixed tool paths and an empty environment.
        task.arguments = ["-c", "/bin/sleep 1; /usr/bin/open \"$0\"", url.path]
        task.environment = [:]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openFolder() {
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func showLast() {
        if let url = lastRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    /// "2026-11-25 001": date plus the next free number for that day in the folder.
    static func nextBaseName(in folder: URL) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let used = names.compactMap { name -> Int? in
            guard name.hasPrefix(day + " ") else { return nil }
            return Int(name.dropFirst(day.count + 1).prefix(3))
        }
        return String(format: "%@ %03d", day, (used.max() ?? 0) + 1)
    }

    @objc private func startRecording() {
        guard state == .idle else { return }
        var mic = Devices.selectedMicrophone()
        if mic != nil, Permissions.micStatus != .authorized {
            if Permissions.micStatus == .notDetermined {
                Permissions.requestMic { [weak self] _ in self?.startRecording() }
                return
            }
            mic = nil
            log.info("Microphone permission denied; recording without microphone")
        }

        let folder = Settings.saveFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showError(error)
            return
        }
        let baseURL = folder.appendingPathComponent(Self.nextBaseName(in: folder))

        let target: CaptureTarget
        switch Settings.sourceMode {
        case "all":
            target = .displays(Devices.displaysLeftToRight())
        case "window":
            guard let w = Settings.selectedWindow else {
                showError(RecorderError.noWindow)
                return
            }
            target = .window(w.id)
        default:
            let id = Settings.displayID == 0 ? CGMainDisplayID() : Settings.displayID
            target = .displays([Devices.displaysLeftToRight().contains(id) ? id : CGMainDisplayID()])
        }
        if let free = Self.freeSpace(at: folder), free < 2_000_000_000 {
            showError(RecorderError.lowDisk)
            return
        }

        var overlay = Settings.overlay
        if overlay.enabled, Permissions.cameraStatus != .authorized { overlay.enabled = false }

        // Bubble mode: put the bubble on screen first so its window can be included in the capture.
        // Window recordings can't see the bubble, so they always draw the camera into the video.
        var ownWindows: [CGWindowID] = []
        if Settings.cameraMode == .bubble, case .displays(let ids) = target {
            bubble.show(config: overlay, deviceID: Settings.cameraDeviceID, displays: ids)
            bubbleDisplays = ids
            if let id = bubble.windowID { ownWindows = [id] }
        }

        let request = RecordingRequest(
            target: target, multiOutput: Settings.multiOutput, microphone: mic, systemAudio: Settings.systemAudio,
            fps: Settings.fps,
            maxShortSide: Settings.maxShortSide, format: Settings.videoFormat, showCursor: Settings.showCursor,
            includeOwnWindows: ownWindows, combinedHeight: Settings.combinedHeight, baseURL: baseURL
        )
        let session = RecordingSession(request: request)
        session.onFailure = { [weak self] error in
            guard let self, self.state == .recording else { return }
            self.stopRecording()
            // A closed window ends a window recording, and the menu-bar indicator's Stop is a normal stop: save quietly.
            switch error {
            case RecorderError.windowClosed: log.notice("Recorded window closed; recording saved")
            case RecorderError.stoppedBySystem: log.notice("Stopped from the system menu bar; recording saved")
            default:
                self.showError(error)
            }
        }
        self.session = session
        state = .starting
        if bubbleDisplays == nil {
            session.setOverlay(overlay, deviceID: Settings.cameraDeviceID) // camera warms up while capture starts
        }

        Task { @MainActor in
            do {
                try await session.start()
                journal(add: session)
                sleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Screen recording"
                )
                state = .recording
                startDiskWatch(folder: folder)
            } catch {
                self.session = nil
                endBubble()
                state = .idle
                showError(error)
            }
        }
    }

    @objc private func stopRecording() {
        guard state == .recording, let session else { return }
        state = .finalizing
        diskTimer?.invalidate()
        diskTimer = nil
        Task { @MainActor in
            do {
                let urls = try await session.stop()
                journalClear()
                lastRecording = urls.first
                log.notice("Saved \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
                let options = PostProcessor.Options.current()
                let base = session.request.baseURL.lastPathComponent
                Task.detached { await PostProcessor.shared.process(urls, baseName: base, options: options) }
            } catch {
                showError(error)
            }
            if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
            sleepActivity = nil
            endBubble()
            self.session = nil
            state = .idle
            if terminateAfterStop { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    private func endBubble() {
        bubble.hide()
        bubbleDisplays = nil
    }

    // MARK: - Disk space

    static func freeSpace(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// Stops the recording before the disk fills up.
    private func startDiskWatch(folder: URL) {
        diskTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.state == .recording,
                  let free = Self.freeSpace(at: folder), free < 1_000_000_000 else { return }
            log.error("Low disk space; stopping recording")
            self.stopRecording()
            self.showError(RecorderError.lowDisk)
        }
    }

    // MARK: - Notifications

    private func notifySaved(_ url: URL, title: String = "Recording saved") {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = url.deletingPathExtension().lastPathComponent
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    private func showError(_ error: Error) {
        log.error("\(error.localizedDescription, privacy: .private)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

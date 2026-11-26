import AppKit
import AVFoundation
import CoreMedia
import OSLog
import RecorderCore

let log = Logger(subsystem: "io.github.yevgenmalafeyev.mrecorder", category: "app")

/// Current host time in seconds, on the same clock ScreenCaptureKit uses for sample timestamps.
func hostNow() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// Minimal lock-protected box.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

// MARK: - Settings

/// User settings persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    /// Selected display (CGDirectDisplayID). 0 = main display.
    static var displayID: UInt32 {
        get { UInt32(d.integer(forKey: "displayID")) }
        set { d.set(Int(newValue), forKey: "displayID") }
    }

    /// Microphone uniqueID; "" = microphone off; nil (never set) = system default.
    static var micDeviceID: String? {
        get { d.string(forKey: "micDeviceID") }
        set { d.set(newValue, forKey: "micDeviceID") }
    }

    /// Record the sound of other apps.
    static var systemAudio: Bool {
        get { bool(Keys.systemAudio, default: true) }
        set { d.set(newValue, forKey: Keys.systemAudio) }
    }

    static var fps: Int {
        get { let v = d.integer(forKey: Keys.fps); return v > 0 ? v : 30 }
        set { d.set(newValue, forKey: Keys.fps) }
    }

    static var videoFormat: VideoFormat { VideoFormat(rawValue: d.string(forKey: Keys.videoFormat) ?? "") ?? .hevc }
    static var showCursor: Bool { bool(Keys.showCursor, default: true) }
    static var cameraMode: CameraMode { CameraMode(rawValue: d.string(forKey: Keys.cameraMode) ?? "") ?? .composited }

    static let defaultSaveFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Recordings", isDirectory: true)

    static var saveFolder: URL {
        get {
            if let path = d.string(forKey: Keys.saveFolder), !path.isEmpty { return URL(fileURLWithPath: path) }
            return defaultSaveFolder
        }
        set { d.set(newValue.path, forKey: Keys.saveFolder) }
    }

    /// Maximum resolution: the shorter side of the video is capped at this many pixels. 0 = original.
    static var maxShortSide: Int { d.integer(forKey: Keys.maxShortSide) }

    static var namingMode: NamingMode { NamingMode(rawValue: d.string(forKey: Keys.namingMode) ?? "") ?? .dateCounter }

    static func bool(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    static var normalizeAudio: Bool { bool(Keys.normalizeAudio, default: false) }
    static var transcribe: Bool { bool(Keys.transcribe, default: true) }
    static var embedSubtitles: Bool { bool(Keys.embedSubtitles, default: true) }
    static var summaryEnabled: Bool { bool(Keys.summary, default: true) }
    static var summaryShort: Bool { bool(Keys.summaryShort, default: true) }
    static var summaryActions: Bool { bool(Keys.summaryActions, default: true) }
    static var summaryChapters: Bool { bool(Keys.summaryChapters, default: true) }
    static var summaryTranscript: Bool { bool(Keys.summaryTranscript, default: true) }

    /// "display" (one screen), "all" (all screens side by side / separately), or "window".
    static var sourceMode: String {
        get { d.string(forKey: Keys.sourceMode) ?? "display" }
        set { d.set(newValue, forKey: Keys.sourceMode) }
    }

    static var multiOutput: MultiDisplayOutput {
        get { MultiDisplayOutput(rawValue: d.string(forKey: Keys.multiOutput) ?? "") ?? .combined }
        set { d.set(newValue.rawValue, forKey: Keys.multiOutput) }
    }

    /// Height of the combined side-by-side video.
    static var combinedHeight: Int {
        let v = d.integer(forKey: Keys.combinedHeight)
        return v > 0 ? v : 2160
    }

    /// Window chosen for window mode (not persisted: windows come and go).
    static var selectedWindow: (id: CGWindowID, title: String)?

    // Camera overlay
    static var overlay: OverlayConfig {
        get {
            OverlayConfig(
                enabled: d.bool(forKey: Keys.cameraOn),
                shape: OverlayShape(rawValue: d.string(forKey: Keys.cameraShape) ?? "") ?? .circle,
                corner: OverlayCorner(rawValue: d.string(forKey: Keys.cameraCorner) ?? "") ?? .bottomRight,
                size: d.double(forKey: Keys.cameraSize) > 0 ? clampedCameraSize(d.double(forKey: Keys.cameraSize)) : 0.22,
                mirror: bool(Keys.cameraMirror, default: true)
            )
        }
        set {
            d.set(newValue.enabled, forKey: Keys.cameraOn)
            d.set(newValue.shape.rawValue, forKey: Keys.cameraShape)
            d.set(newValue.corner.rawValue, forKey: Keys.cameraCorner)
            d.set(newValue.size, forKey: Keys.cameraSize)
            d.set(newValue.mirror, forKey: Keys.cameraMirror)
        }
    }

    /// Camera height as a fraction of the video's shorter side, kept to a sane range (also rejects inf/NaN).
    static func clampedCameraSize(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0.1), 0.4) : 0.22
    }

    /// mrecorder:// links may start, stop and change recordings. Off: a link only opens the New Recording window.
    static var allowURLControl: Bool { bool(Keys.allowURLControl, default: false) }

    /// Camera uniqueID; nil = system default camera.
    static var cameraDeviceID: String? {
        get { d.string(forKey: Keys.cameraDevice) }
        set { d.set(newValue, forKey: Keys.cameraDevice) }
    }

    enum Keys {
        static let fps = "fps"
        static let videoFormat = "videoFormat"
        static let showCursor = "showCursor"
        static let cameraMode = "cameraMode"
        static let sourceMode = "sourceMode"
        static let multiOutput = "multiOutput"
        static let combinedHeight = "combinedHeight"
        static let systemAudio = "systemAudio"
        static let allowURLControl = "allowURLControl"

        static let cameraOn = "cameraOn"
        static let cameraShape = "cameraShape"
        static let cameraCorner = "cameraCorner"
        static let cameraSize = "cameraSize"
        static let cameraMirror = "cameraMirror"
        static let cameraDevice = "cameraDevice"

        static let saveFolder = "saveFolder"
        static let maxShortSide = "maxShortSide"
        static let namingMode = "namingMode"
        static let normalizeAudio = "normalizeAudio"
        static let unfinished = "unfinishedRecordings"
        static let transcribe = "transcribe"
        static let embedSubtitles = "embedSubtitles"
        static let summary = "summary"
        static let summaryShort = "summaryShort"
        static let summaryActions = "summaryActions"
        static let summaryChapters = "summaryChapters"
        static let summaryTranscript = "summaryTranscript"
    }
}

/// Camera drawn into the video only, or a floating bubble on screen that is recorded with the screen.
enum CameraMode: String, CaseIterable {
    case composited, bubble
}

enum NamingMode: String, CaseIterable {
    case dateCounter = "date"
    case claude = "claude"
}

// MARK: - Permissions

enum Permissions {
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestCamera(completion: @escaping (Bool) -> Void) {
        switch cameraStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok) } }
        case .authorized:
            completion(true)
        default:
            openSettings("Privacy_Camera")
            completion(false)
        }
    }

    static func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
    }

    static func requestMic(completion: @escaping (Bool) -> Void) {
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok) } }
        case .authorized:
            completion(true)
        default:
            openSettings("Privacy_Microphone")
            completion(false)
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Devices

enum Devices {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// The microphone to record, or nil when the microphone is off.
    static func selectedMicrophone() -> AVCaptureDevice? {
        switch Settings.micDeviceID {
        case .some(""): return nil
        case .some(let id): return AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .audio)
        case .none: return AVCaptureDevice.default(for: .audio)
        }
    }

    /// The chosen microphone, or the system default when the microphone is off.
    static func selectedMicrophoneOrDefault() -> AVCaptureDevice? {
        selectedMicrophone() ?? AVCaptureDevice.default(for: .audio) ?? microphones().first
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { $0.deviceType != .deskViewCamera }
    }

    static func camera(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video) ?? cameras().first
    }

    static func displayName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if n == id { return screen.localizedName }
        }
        return "Display \(id)"
    }

    static var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    /// All active displays ordered left to right.
    static func displaysLeftToRight() -> [CGDirectDisplayID] {
        NSScreen.screens
            .compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
            .sorted { CGDisplayBounds($0).minX < CGDisplayBounds($1).minX }
    }

    struct WindowInfo {
        let id: CGWindowID
        let app: String
        let title: String
        var label: String { title.isEmpty ? app : "\(app) — \(title)" }
    }

    /// Normal on-screen windows of other apps, front to back.
    static func windows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let app = w[kCGWindowOwnerName as String] as? String,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 120, (b["Height"] ?? 0) > 120
            else { return nil }
            return WindowInfo(id: id, app: app, title: w[kCGWindowName as String] as? String ?? "")
        }
    }
}

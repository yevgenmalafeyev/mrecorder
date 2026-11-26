import AppKit
import AVFoundation
import RecorderCore

/// Floating camera bubble (Loom-style): a borderless panel above all windows, snapped to a corner,
/// that is recorded together with the screen. It ignores the mouse so it never blocks clicks.
///
/// While a recording is running the panel stays on screen (fully transparent when the camera is off),
/// so its window can be included in the capture filter from the start.
final class BubbleController {
    private var panel: NSPanel?
    private let container = NSView()
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let sessionQueue = DispatchQueue(label: "recorder.bubble")
    private var currentDeviceID: String?
    private var running = false
    private var mirror = true

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    /// Window number of the bubble, once it is on screen.
    var windowID: CGWindowID? {
        guard let p = panel, p.windowNumber > 0 else { return nil }
        return CGWindowID(p.windowNumber)
    }

    /// Puts the bubble on screen (visible only if the camera is on) and starts the camera if needed.
    func show(config: OverlayConfig, deviceID: String?, displays: [CGDirectDisplayID]) {
        let p = panel ?? makePanel()
        panel = p
        layout(config: config, displays: displays)
        p.orderFrontRegardless()
        setCamera(on: config.enabled, deviceID: deviceID)
    }

    /// Applies shape, corner, size, mirroring and on/off immediately.
    func update(config: OverlayConfig, deviceID: String?, displays: [CGDirectDisplayID]) {
        guard panel != nil else { return }
        layout(config: config, displays: displays)
        setCamera(on: config.enabled, deviceID: deviceID)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        setCamera(on: false, deviceID: nil)
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.title = "Camera Bubble"

        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        container.layer?.borderWidth = 3
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.addSublayer(previewLayer)
        p.contentView = container
        return p
    }

    private func layout(config: OverlayConfig, displays: [CGDirectDisplayID]) {
        guard let p = panel else { return }
        // Two or more screens: left corners on the leftmost screen, right corners on the rightmost.
        let index = CanvasLayout.overlayTarget(corner: config.corner, count: displays.count)
        let displayID = displays.isEmpty ? CGMainDisplayID() : displays[index]
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        } ?? NSScreen.main ?? NSScreen.screens[0]

        // Same geometry as the composited overlay, measured in points on that screen's visible area.
        let frame = screen.visibleFrame
        let r = OverlayGeometry.rect(canvas: frame.size, config: config)
        let rect = NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.setFrame(rect, display: true)
        container.frame = NSRect(origin: .zero, size: rect.size)
        container.layer?.cornerRadius = config.shape == .circle ? rect.height / 2 : rect.height * 0.08
        previewLayer.frame = container.bounds
        mirror = config.mirror
        applyMirror()
        CATransaction.commit()
        p.alphaValue = config.enabled ? 1 : 0
        p.invalidateShadow()
    }

    /// The preview connection exists only once the camera input is added, so this runs again after start.
    private func applyMirror() {
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
    }

    private func setCamera(on: Bool, deviceID: String?) {
        if on {
            let device = Devices.camera(id: deviceID)
            if running, currentDeviceID == device?.uniqueID { return }
            currentDeviceID = device?.uniqueID
            running = true
            sessionQueue.async { [self, session] in
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                DispatchQueue.main.async { self.applyMirror() }
            }
        } else if running {
            running = false
            currentDeviceID = nil
            sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
        }
    }
}

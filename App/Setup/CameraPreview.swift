import AppKit
import AVFoundation
import RecorderCore
import SwiftUI

/// Live camera picture for the setup window, so you can see how you sit in the bubble before recording.
/// Uses the same camera format and centred crop as the recording. Create and use from the main thread.
final class CameraPreview: @unchecked Sendable {
    let layer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "recorder.setup-preview")
    /// Used on `queue` only.
    private var currentDeviceID: String?
    private var mirror = true

    init() {
        layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
    }

    /// Starts (or switches to) the given camera; nil = the default camera.
    func start(deviceID: String?) {
        queue.async { [self] in
            guard let device = Devices.camera(id: deviceID) else { return }
            if session.isRunning, currentDeviceID == device.uniqueID { return }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            session.commitConfiguration()
            currentDeviceID = device.uniqueID
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.applyMirror() }
        }
    }

    /// Stops the camera, so its light goes off.
    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            currentDeviceID = nil
        }
    }

    func setMirror(_ on: Bool) {
        mirror = on
        applyMirror()
    }

    /// The preview connection exists only once the camera input is added, so this runs again after start.
    private func applyMirror() {
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
    }
}

/// The camera picture cut to the bubble's shape.
struct CameraPreviewView: NSViewRepresentable {
    let preview: CameraPreview
    let shape: OverlayShape
    let mirror: Bool

    func makeNSView(context: Context) -> ShapedView {
        let v = ShapedView(preview.layer)
        v.shape = shape
        preview.setMirror(mirror)
        return v
    }

    func updateNSView(_ view: ShapedView, context: Context) {
        view.shape = shape
        preview.setMirror(mirror)
    }

    final class ShapedView: NSView {
        private let content: CALayer
        var shape: OverlayShape = .circle { didSet { needsLayout = true } }

        init(_ content: CALayer) {
            self.content = content
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.borderWidth = 2
            layer?.addSublayer(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.frame = bounds
            // Same rounding as the bubble in the recording.
            layer?.cornerRadius = shape == .circle ? bounds.height / 2 : bounds.height * 0.08
            CATransaction.commit()
        }
    }
}

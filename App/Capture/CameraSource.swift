import AVFoundation

/// Runs the camera and keeps only its latest frame. The session runs only while the overlay
/// is on, so the camera light goes off when the overlay is switched off.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "recorder.camera", qos: .userInteractive)
    private let latest = Locked<CVPixelBuffer?>(nil)
    private var currentDeviceID: String?
    /// False once stop() is called, so frames still queued after stopping are ignored.
    private let active = Locked(false)

    var frame: CVPixelBuffer? { latest.get() }

    /// Starts (or switches to) the given camera. Runs asynchronously; frames appear ~0.5 s later.
    func start(deviceID: String?) {
        active.set(true)
        queue.async { [self] in
            guard active.get() else { return } // stopped before this ran
            guard let device = Devices.camera(id: deviceID) else {
                log.error("No camera available")
                return
            }
            if session.isRunning, currentDeviceID == device.uniqueID { return }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw RecorderError.capture("camera input") }
                session.addInput(input)
            } catch {
                log.error("Camera input failed: \(error.localizedDescription, privacy: .public)")
                session.commitConfiguration()
                return
            }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            currentDeviceID = device.uniqueID
            latest.set(nil)
            if !session.isRunning { session.startRunning() }
            log.notice("Camera started: \(device.localizedName, privacy: .public)")
        }
    }

    func stop() {
        active.set(false)
        latest.set(nil)
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            latest.set(nil)
            currentDeviceID = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active.get(), let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if latest.get() == nil {
            log.notice("First camera frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
        latest.set(pb)
    }
}

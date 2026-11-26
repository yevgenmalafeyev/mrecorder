import AppKit
import AVFoundation
import CoreMedia
import RecorderCore
import ScreenCaptureKit

/// The latest few captured frames with their capture time (host seconds).
private struct FrameRing {
    struct Frame {
        let time: Double
        let buffer: CVPixelBuffer
        /// Part of the buffer with content (Core Image coordinates), when smaller than the buffer.
        let crop: CGRect?
    }
    private(set) var frames: [Frame] = []
    let capacity = 3

    mutating func push(_ frame: Frame) {
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }

    /// Newest frame captured at or before `time`; falls back to the oldest one held.
    func frame(atOrBefore time: Double) -> Frame? {
        frames.last(where: { $0.time <= time }) ?? frames.first
    }
}

/// What to capture.
enum CaptureTarget {
    /// One or more displays, in left-to-right order.
    case displays([CGDirectDisplayID])
    case window(CGWindowID)
}

/// With two or more displays: one combined side-by-side file, one file per display, or both.
enum MultiDisplayOutput: String, CaseIterable {
    case combined, separate, both
}

struct RecordingRequest {
    let target: CaptureTarget
    let multiOutput: MultiDisplayOutput
    let microphone: AVCaptureDevice?
    /// Record the sound of other apps (call participants, videos). Off keeps a silent System track.
    let systemAudio: Bool
    let fps: Int
    let maxShortSide: Int
    let format: VideoFormat
    let showCursor: Bool
    /// Our own windows to keep in the recording (the camera bubble); all others of this app are excluded.
    let includeOwnWindows: [CGWindowID]
    /// Combined video height for several displays (capped by `maxShortSide` when set).
    let combinedHeight: Int
    /// Folder and base name without extension, e.g. ".../2026-11-25 001".
    let baseURL: URL
}

/// Records displays or a window, system audio and microphone into one or more files.
///
/// Timing model: the anchor is the capture time at which every source has delivered a frame.
/// Video frame k is written at k/fps and shows, per source, the newest frame captured at or before
/// that output time (pauses cut out). Audio is placed by capture timestamp and written by sample count.
/// All output files share the anchor, frame grid, pauses and audio, so they stay in sync.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let request: RecordingRequest

    private final class Source {
        let name: String
        let captureSize: CGSize
        let isWindow: Bool
        var stream: SCStream?
        var ring = FrameRing()
        var firstFrameTime: Double?
        init(name: String, captureSize: CGSize, isWindow: Bool) {
            self.name = name
            self.captureSize = captureSize
            self.isWindow = isWindow
        }
    }

    private struct Output {
        let writer: OutputWriter
        let canvas: CGSize
        /// (source index, placement on the canvas)
        let layers: [(source: Int, rect: CGRect)]
        let drawsCamera: Bool
    }

    private let videoQueue = DispatchQueue(label: "recorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "recorder.audio", qos: .userInteractive)
    private let discardQueue = DispatchQueue(label: "recorder.discard", qos: .utility)
    private let discard = DiscardOutput()

    private var sources: [Source] = []
    private var sourceIndex: [ObjectIdentifier: Int] = [:]
    private var outputs: [Output] = []
    /// Files being written, main file first (known once `start()` has created the writers).
    var outputURLs: [URL] { outputs.map(\.writer.url) }
    private var audioStream: SCStream?

    /// Video delay: frame k is produced once its time is this far in the past,
    /// so frames still in flight from ScreenCaptureKit are not missed.
    private let videoDelay = 0.06
    private let timeline = Locked<Timeline?>(nil)
    private let overlay = Locked(OverlayConfig())
    private let camera = CameraSource()
    private let compositor = Compositor()
    private var cameraDeviceID: String?
    private let firstFrame = Locked<CheckedContinuation<Void, Never>?>(nil)
    private let micMuted = Locked(false)

    // Video queue state
    private var nextIndex: Int64 = 0
    private var frameTimer: DispatchSourceTimer?
    private var skippedFrames = 0

    // Audio queue state
    private let systemConverter = AudioInputConverter(channels: 2)
    private let micConverter = AudioInputConverter(channels: 1)
    private var systemAligner = TimelineAligner(channels: 2)
    private var micAligner = TimelineAligner(channels: 1)
    private var systemForMix = AudioFIFO(channels: 2)
    private var micForMix = AudioFIFO(channels: 1)
    private var mixer = Mixer()
    private var audioTimer: DispatchSourceTimer?
    private var stopping = false

    /// Called on the main queue if capture stops unexpectedly (display unplugged, window closed).
    var onFailure: ((Error) -> Void)?

    init(request: RecordingRequest) {
        self.request = request
    }

    /// Recorded duration so far (excludes pauses).
    var elapsed: Double { timeline.get()?.outputSecondsClamped(host: hostNow()) ?? 0 }
    var isPaused: Bool { timeline.get()?.isPaused ?? false }
    var hasStarted: Bool { timeline.get() != nil }

    var isMicMuted: Bool { micMuted.get() }

    /// While muted the microphone is recorded as silence, so the timing of the tracks is kept.
    func setMicMuted(_ muted: Bool) {
        micMuted.set(muted)
        log.notice("Microphone \(muted ? "muted" : "unmuted", privacy: .public) at \(self.elapsed, format: .fixed(precision: 2)) s")
    }

    // MARK: - Pause and camera (call from main)

    func pause() {
        timeline.update { $0?.pause(at: hostNow()) }
        log.notice("Paused at \(self.elapsed, format: .fixed(precision: 2)) s")
    }

    func resume() {
        timeline.update { $0?.resume(at: hostNow()) }
        log.notice("Resumed; total paused \(self.timeline.get()?.totalPaused ?? 0, format: .fixed(precision: 2)) s")
    }

    /// Applies camera overlay settings immediately; starts or stops the camera as needed.
    func setOverlay(_ config: OverlayConfig, deviceID: String?) {
        let previous = overlay.get()
        overlay.set(config)
        if config.enabled {
            if !previous.enabled || deviceID != cameraDeviceID { camera.start(deviceID: deviceID) }
        } else if previous.enabled {
            camera.stop()
        }
        cameraDeviceID = deviceID
    }

    // MARK: - Start

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let ownIncluded = content.windows.filter { request.includeOwnWindows.contains($0.windowID) }
        if ownIncluded.count != request.includeOwnWindows.count { log.error("Camera bubble window not found for capture") }

        // 1. Capture filters and native sizes
        var filters: [(name: String, filter: SCContentFilter, native: CGSize, isWindow: Bool)] = []
        switch request.target {
        case .displays(let ids):
            for id in ids {
                guard let d = content.displays.first(where: { $0.displayID == id }) else { continue }
                // Exclude this app's own windows (menus, alerts) from the recording.
                let f = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: ownIncluded)
                filters.append((Devices.displayName(for: id), f, Self.pixelSize(f), false))
            }
            guard !filters.isEmpty else { throw RecorderError.noDisplay }
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.noWindow }
            let f = SCContentFilter(desktopIndependentWindow: w)
            filters.append((w.owningApplication?.applicationName ?? "Window", f, Self.pixelSize(f), true))
        }

        // 2. Output plan
        let multi = filters.count > 1
        let wantCombined = multi && request.multiOutput != .separate
        let wantSeparate = !multi || request.multiOutput != .combined
        let combinedHeight = request.maxShortSide > 0 ? min(request.combinedHeight, request.maxShortSide) : request.combinedHeight
        let maxDim = request.format.maxDimension
        let layout = CanvasLayout.sideBySide(sources: filters.map(\.native), height: combinedHeight, maxDimension: maxDim)

        // When only the combined file is written, let ScreenCaptureKit scale each display to its slot.
        let captureSizes: [CGSize] = filters.indices.map { i in
            wantSeparate
                ? CanvasLayout.fit(CanvasLayout.capped(filters[i].native, maxShortSide: request.maxShortSide), maxDimension: maxDim)
                : layout.slots[i].size
        }
        sources = filters.indices.map { i in
            Source(name: filters[i].name, captureSize: captureSizes[i], isWindow: filters[i].isWindow)
        }

        let includeMic = request.microphone != nil
        let corner = overlay.get().corner
        if wantCombined {
            let w = try OutputWriter(url: urlFor(suffix: nil), width: Int(layout.canvas.width),
                                     height: Int(layout.canvas.height), fps: request.fps, includeMic: includeMic,
                                     format: request.format)
            outputs.append(Output(writer: w, canvas: layout.canvas,
                                  layers: layout.slots.enumerated().map { ($0.offset, $0.element) }, drawsCamera: true))
        }
        if wantSeparate {
            let cameraTarget = CanvasLayout.overlayTarget(corner: corner, count: sources.count)
            for (i, s) in sources.enumerated() {
                let suffix = multi ? s.name : nil
                let w = try OutputWriter(url: urlFor(suffix: suffix), width: Int(s.captureSize.width),
                                         height: Int(s.captureSize.height), fps: request.fps, includeMic: includeMic,
                                     format: request.format)
                outputs.append(Output(writer: w, canvas: s.captureSize,
                                      layers: [(i, CGRect(origin: .zero, size: s.captureSize))],
                                      drawsCamera: !multi || i == cameraTarget))
            }
        }
        for o in outputs {
            log.notice("Output \(o.writer.url.lastPathComponent, privacy: .public): \(Int(o.canvas.width))x\(Int(o.canvas.height)) @\(self.request.fps) fps")
        }

        // 3. Video streams
        for (i, f) in filters.enumerated() {
            let cfg = SCStreamConfiguration()
            cfg.width = Int(captureSizes[i].width)
            cfg.height = Int(captureSizes[i].height)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            cfg.queueDepth = 8
            cfg.showsCursor = request.showCursor
            cfg.capturesAudio = false
            if f.isWindow {
                // Keep a resized window fully visible inside the fixed frame.
                cfg.scalesToFit = true
                cfg.preservesAspectRatio = true
            }
            let stream = SCStream(filter: f.filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            sources[i].stream = stream
            sourceIndex[ObjectIdentifier(stream)] = i
        }

        // 4. Audio stream: system audio (all apps, incl. call participants) + microphone.
        // Audio is not display-scoped, so a tiny full-display stream hears everything.
        guard let audioDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw RecorderError.noDisplay }
        let acfg = SCStreamConfiguration()
        // System audio that is not wanted is still dropped below; capturing stays on with a microphone.
        acfg.capturesAudio = request.systemAudio || request.microphone != nil
        acfg.sampleRate = Int(AudioInputConverter.sampleRate)
        acfg.channelCount = 2
        acfg.excludesCurrentProcessAudio = true
        acfg.width = 2
        acfg.height = 2
        acfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        acfg.showsCursor = false
        acfg.queueDepth = 3
        if let mic = request.microphone {
            acfg.captureMicrophone = true
            acfg.microphoneCaptureDeviceID = mic.uniqueID
        }
        let aus = SCStream(filter: SCContentFilter(display: audioDisplay, excludingWindows: []), configuration: acfg, delegate: self)
        if acfg.capturesAudio { try aus.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if request.microphone != nil {
            try aus.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        // SCStream renders (tiny) video regardless; take and drop it to avoid error logs.
        try aus.addStreamOutput(discard, type: .screen, sampleHandlerQueue: discardQueue)
        audioStream = aus

        try await aus.startCapture()
        for s in sources { try await s.stream?.startCapture() }

        // 5. Wait until every source delivered a frame (that sets the anchor), at most 3 s.
        let gotFrames = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    if self.timeline.get() != nil { cont.resume() } else { self.firstFrame.set(cont) }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first, let cont = self.firstFrame.update({ c -> CheckedContinuation<Void, Never>? in
                defer { c = nil }; return c
            }) { cont.resume() }
            return first
        }
        guard gotFrames else {
            await stopStreams()
            for o in outputs {
                o.writer.cancel()
                try? FileManager.default.removeItem(at: o.writer.url)
            }
            throw RecorderError.noFrames
        }

        startTimers()
    }

    private func urlFor(suffix: String?) -> URL {
        let base = request.baseURL.lastPathComponent
        // Display names come from the monitor (EDID, AirPlay, virtual displays): keep them to one plain path component.
        let safe = suffix.map {
            String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
                .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        let name = safe.map { $0.isEmpty ? base : "\(base) (\($0))" } ?? base
        return request.baseURL.deletingLastPathComponent().appendingPathComponent(name + "." + request.format.fileExtension)
    }

    private static func pixelSize(_ filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        return CGSize(width: FrameGrid.even(Double(filter.contentRect.width * scale)),
                      height: FrameGrid.even(Double(filter.contentRect.height * scale)))
    }

    private func startTimers() {
        let ft = DispatchSource.makeTimerSource(flags: .strict, queue: videoQueue)
        ft.schedule(deadline: .now(), repeating: 1.0 / Double(request.fps) / 2, leeway: .milliseconds(1))
        ft.setEventHandler { [weak self] in self?.videoTick(until: hostNow()) }
        ft.resume()
        frameTimer = ft

        let at = DispatchSource.makeTimerSource(queue: audioQueue)
        at.schedule(deadline: .now(), repeating: 0.05, leeway: .milliseconds(5))
        at.setEventHandler { [weak self] in self?.audioTick(now: hostNow()) }
        at.resume()
        audioTimer = at
    }

    // MARK: - Stop

    /// Stops recording and finalizes all files. Returns the file URLs, main file first.
    func stop() async throws -> [URL] {
        let stopHost = hostNow()
        guard let tl = timeline.get() else { throw RecorderError.noFrames }
        let endSeconds = tl.outputSecondsClamped(host: stopHost)
        let lastIndex = FrameGrid.lastIndex(atOrBefore: endSeconds, fps: request.fps)

        // Finish video up to the stop time.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                self.frameTimer?.cancel()
                self.frameTimer = nil
                self.videoTick(until: stopHost + self.videoDelay, maxIndex: lastIndex)
                cont.resume()
            }
        }

        // Finish audio: pad every source to the stop time, mix, and write everything.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            audioQueue.async {
                self.audioTimer?.cancel()
                self.audioTimer = nil
                self.stopping = true
                self.padAll(to: Int64(endSeconds * AudioInputConverter.sampleRate))
                self.mixAvailable()
                let tracks = self.outputs.flatMap { $0.writer.audioTracks }
                let deadline = hostNow() + 3
                while tracks.contains(where: { $0.pendingFrames > 0 }), hostNow() < deadline {
                    for t in tracks { t.drain(all: true) }
                    if tracks.contains(where: { $0.pendingFrames > 0 }) { usleep(5_000) }
                }
                cont.resume()
            }
        }

        camera.stop()
        await stopStreams()
        if skippedFrames > 0 { log.notice("Skipped \(self.skippedFrames) video frames (encoder busy)") }
        var urls: [URL] = []
        for o in outputs {
            try await o.writer.finish(endSeconds: endSeconds)
            urls.append(o.writer.url)
        }
        return urls
    }

    private func stopStreams() async {
        for s in sources {
            if let st = s.stream { try? await st.stopCapture() }
            s.stream = nil
        }
        if let s = audioStream { try? await s.stopCapture() }
        audioStream = nil
    }

    // MARK: - Video

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: handleScreen(sampleBuffer, from: stream)
        case .audio: handleAudio(sampleBuffer, isMic: false)
        case .microphone: handleAudio(sampleBuffer, isMic: true)
        @unknown default: break
        }
    }

    private func handleScreen(_ sb: CMSampleBuffer, from stream: SCStream) {
        guard let i = sourceIndex[ObjectIdentifier(stream)],
              sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb)
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let source = sources[i]
        let crop = source.isWindow ? Self.contentCrop(attachments.first ?? [:], buffer: pixelBuffer) : nil
        source.ring.push(FrameRing.Frame(time: time, buffer: pixelBuffer, crop: crop))
        if source.firstFrameTime == nil { source.firstFrameTime = time }

        if timeline.get() == nil, sources.allSatisfy({ $0.firstFrameTime != nil }) {
            let anchor = sources.compactMap(\.firstFrameTime).max() ?? time
            timeline.set(Timeline(anchor: anchor))
            log.notice("Anchor set: all \(self.sources.count) sources delivered frames")
            if let cont = firstFrame.update({ c -> CheckedContinuation<Void, Never>? in defer { c = nil }; return c }) {
                cont.resume()
            }
        }
    }

    /// For a window scaled to fit a fixed frame, ScreenCaptureKit draws it in the top-left corner.
    /// Returns the area that holds the window (Core Image coordinates) so it can be centred.
    private static func contentCrop(_ info: [SCStreamFrameInfo: Any], buffer: CVPixelBuffer) -> CGRect? {
        guard let dict = info[.contentRect],
              let rect = CGRect(dictionaryRepresentation: dict as! CFDictionary),
              rect.width > 0, rect.height > 0
        else { return nil }
        // The window is scaled to fit the frame with its aspect ratio kept, anchored top-left.
        let bw = CGFloat(CVPixelBufferGetWidth(buffer)), bh = CGFloat(CVPixelBufferGetHeight(buffer))
        let s = min(bw / rect.width, bh / rect.height)
        let w = (rect.width * s).rounded(.down), h = (rect.height * s).rounded(.down)
        guard w > 16, h > 16, w < bw - 2 || h < bh - 2 else { return nil }
        return CGRect(x: 0, y: bh - h, width: w, height: h)
    }

    /// Writes every frame index whose time (plus the delay) has passed. Runs on the video queue.
    private func videoTick(until now: Double, maxIndex: Int64? = nil) {
        guard let tl = timeline.get(), !outputs.isEmpty else { return }
        // While paused, output time is frozen, so no new frames are produced.
        var target = FrameGrid.lastIndex(atOrBefore: tl.outputSecondsClamped(host: now - videoDelay), fps: request.fps)
        if let maxIndex { target = min(target, maxIndex) }
        guard target >= nextIndex else { return }
        let config = overlay.get()
        let cameraFrame = config.enabled ? camera.frame : nil

        // After a long stall, don't try to catch up more than 2 s of frames.
        let maxBurst = Int64(request.fps * 2)
        if target - nextIndex > maxBurst {
            skippedFrames += Int(target - nextIndex - maxBurst)
            nextIndex = target - maxBurst
        }
        // Reuse a composite while its inputs are unchanged (static screen repeats within a tick).
        var cache: [Int: (inputs: [CVPixelBuffer], result: CVPixelBuffer)] = [:]

        while nextIndex <= target {
            let t = tl.hostTime(output: Double(nextIndex) / Double(request.fps))
            let frames = sources.map { $0.ring.frame(atOrBefore: t) }
            for (oi, o) in outputs.enumerated() {
                let inputFrames = o.layers.compactMap { frames[$0.source] }
                guard inputFrames.count == o.layers.count else { continue }
                let inputs = inputFrames.map(\.buffer)
                let cam = o.drawsCamera ? cameraFrame : nil
                let frame: CVPixelBuffer
                if o.layers.count == 1, cam == nil, inputFrames[0].crop == nil,
                   CVPixelBufferGetWidth(inputs[0]) == Int(o.canvas.width),
                   CVPixelBufferGetHeight(inputs[0]) == Int(o.canvas.height) {
                    frame = inputs[0] // fast path: no compositing needed
                } else if let c = cache[oi], zip(c.inputs, inputs).allSatisfy({ $0 === $1 }) {
                    frame = c.result
                } else if let pool = o.writer.pixelBufferPool,
                          let out = compositor.compose(
                            layers: zip(inputFrames, o.layers).map {
                                Compositor.Layer(buffer: $0.buffer, rect: $1.rect, crop: $0.crop)
                            },
                            canvas: o.canvas, camera: cam, config: config, pool: pool) {
                    cache[oi] = (inputs, out)
                    frame = out
                } else {
                    continue
                }
                if !o.writer.appendVideo(frame, index: nextIndex) { skippedFrames += 1 }
            }
            nextIndex += 1
        }
        if let error = outputs.lazy.compactMap({ $0.writer.failed }).first { fail(error) }
    }

    // MARK: - Audio

    private func handleAudio(_ sb: CMSampleBuffer, isMic: Bool) {
        guard !stopping, let tl = timeline.get() else { return }
        // Without system audio its track is filled with silence by `audioTick`.
        if !isMic, !request.systemAudio { return }
        let converter = isMic ? micConverter : systemConverter
        guard let (start, converted) = converter.convert(sb) else { return }
        let audio = isMic && micMuted.get() ? converted.map { [Float](repeating: 0, count: $0.count) } : converted
        // Audio captured while paused is dropped.
        guard let position = tl.outputSeconds(host: start) else { return }
        let startFrame = Int64((position * AudioInputConverter.sampleRate).rounded())
        if isMic {
            route(mic: micAligner.ingest(startFrame: startFrame, samples: audio))
        } else {
            route(system: systemAligner.ingest(startFrame: startFrame, samples: audio))
        }
        mixAvailable()
    }

    /// Fills silence for any source that has stopped delivering (more than 250 ms behind).
    private func audioTick(now: Double) {
        guard !stopping, let tl = timeline.get() else { return }
        padAll(to: Int64(tl.outputSecondsClamped(host: now - 0.25) * AudioInputConverter.sampleRate))
        mixAvailable()
    }

    private func padAll(to frame: Int64) {
        route(system: systemAligner.padSilence(upTo: frame))
        if request.microphone != nil { route(mic: micAligner.padSilence(upTo: frame)) }
    }

    private func route(system audio: PlanarAudio) {
        guard PlanarAudioUtil.frameCount(audio) > 0 else { return }
        for o in outputs { o.writer.systemTrack.enqueue(audio) }
        systemForMix.append(audio)
    }

    private func route(mic audio: PlanarAudio) {
        guard PlanarAudioUtil.frameCount(audio) > 0 else { return }
        for o in outputs { o.writer.micTrack?.enqueue(audio) }
        micForMix.append(audio)
    }

    private func mixAvailable() {
        let hasMic = request.microphone != nil
        let n = hasMic ? min(systemForMix.count, micForMix.count) : systemForMix.count
        if n > 0 {
            let sys = systemForMix.pop(n)
            let mic = hasMic ? micForMix.pop(n)[0] : nil
            let mixed = mixer.mix(system: sys, mic: mic)
            for o in outputs { o.writer.mixTrack.enqueue(mixed) }
        }
        for o in outputs { for t in o.writer.audioTracks { t.drain() } }
    }

    // MARK: - Errors

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userStopped.rawValue {
            // Stopped from the system's screen-recording indicator in the menu bar: a normal stop.
            fail(RecorderError.stoppedBySystem)
        } else if case .window = request.target {
            fail(RecorderError.windowClosed)
        } else {
            fail(RecorderError.capture(error.localizedDescription))
        }
    }

    private let failureReported = Locked(false)
    private func fail(_ error: Error) {
        let first = failureReported.update { v -> Bool in defer { v = true }; return !v }
        guard first else { return }
        DispatchQueue.main.async { self.onFailure?(error) }
    }
}

private final class DiscardOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

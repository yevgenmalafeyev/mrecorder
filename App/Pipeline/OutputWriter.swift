import AVFoundation
import CoreMedia
import RecorderCore

/// Container and codec of the recording.
enum VideoFormat: String, CaseIterable {
    case hevc, h264, prores

    var fileType: AVFileType { self == .prores ? .mov : .mp4 }
    var fileExtension: String { self == .prores ? "mov" : "mp4" }
    var codec: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .prores: return .proRes422
        }
    }
    /// Largest width or height the hardware encoder accepts.
    var maxDimension: Int { self == .h264 ? 4096 : 8192 }
    /// ProRes files carry uncompressed audio (what editors expect).
    var pcmAudio: Bool { self == .prores }
}

/// One audio track of the output file. Samples are queued and written back to back,
/// so the track position is simply the number of frames written.
final class AudioTrackWriter {
    let name: String
    let channels: Int
    let input: AVAssetWriterInput
    private var pending: AudioFIFO
    private(set) var framesWritten: Int64 = 0
    private let formatDescription: CMAudioFormatDescription

    init(name: String, channels: Int, bitrate: Int, enabled: Bool, pcm: Bool, realTime: Bool = true) {
        self.name = name
        self.channels = channels
        pending = AudioFIFO(channels: channels)

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = pcm ? [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioInputConverter.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: layoutData,
        ] : [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioInputConverter.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
            AVChannelLayoutKey: layoutData,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = realTime
        input.marksOutputTrackAsEnabled = enabled

        var asbd = AudioStreamBasicDescription(
            mSampleRate: AudioInputConverter.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc
        )
        formatDescription = desc!
    }

    func enqueue(_ audio: PlanarAudio) {
        guard PlanarAudioUtil.frameCount(audio) > 0 else { return }
        pending.append(audio)
    }

    var pendingFrames: Int { pending.count }

    /// Writes queued audio while the input accepts it. With `all`, also writes a final partial chunk.
    func drain(all: Bool = false) {
        let chunk = 4800 // 100 ms
        while input.isReadyForMoreMediaData, pending.count >= (all ? 1 : 1024) {
            let audio = pending.pop(chunk)
            guard let sample = makeSampleBuffer(audio) else { break }
            if !input.append(sample) {
                log.error("Append failed on \(self.name, privacy: .public) track")
                break
            }
            framesWritten += Int64(PlanarAudioUtil.frameCount(audio))
        }
    }

    private func makeSampleBuffer(_ audio: PlanarAudio) -> CMSampleBuffer? {
        let frames = PlanarAudioUtil.frameCount(audio)
        var interleaved = PlanarAudioUtil.interleave(audio)
        let length = interleaved.count * MemoryLayout<Float>.size

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        interleaved.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
        }

        var sample: CMSampleBuffer?
        let pts = CMTime(value: framesWritten, timescale: CMTimeScale(AudioInputConverter.sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

/// Writes one recording file: one video track plus Mix (enabled), System and Microphone audio tracks.
final class OutputWriter {
    let url: URL
    let fps: Int
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let mixTrack: AudioTrackWriter
    let systemTrack: AudioTrackWriter
    let micTrack: AudioTrackWriter?
    private(set) var lastVideoIndex: Int64 = -1

    init(url: URL, width: Int, height: Int, fps: Int, includeMic: Bool, format: VideoFormat) throws {
        self.url = url
        self.fps = fps
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        writer.shouldOptimizeForNetworkUse = false
        // Crash safety: the file is written in fragments, so after a crash or power loss it still plays
        // up to the last few seconds. A normal finish turns it back into an ordinary file.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        // Bits per pixel: screen content compresses well. HEVC needs about half of H.264.
        let bpp = format == .h264 ? 0.07 : 0.04
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * bpp))
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps]
        if format != .prores {
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoMaxKeyFrameIntervalKey] = fps * 2
            compression[AVVideoAllowFrameReorderingKey] = false
        }
        let video: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        let pcm = format.pcmAudio
        mixTrack = AudioTrackWriter(name: "Mix", channels: 2, bitrate: 160_000, enabled: true, pcm: pcm)
        systemTrack = AudioTrackWriter(name: "System", channels: 2, bitrate: 160_000, enabled: false, pcm: pcm)
        micTrack = includeMic ? AudioTrackWriter(name: "Microphone", channels: 1, bitrate: 96_000, enabled: false, pcm: pcm) : nil

        for input in [videoInput, mixTrack.input, systemTrack.input] + [micTrack?.input].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw RecorderError.writer("cannot add \(input.mediaType.rawValue) input") }
            writer.add(input)
        }
        // Alternate group: players pick the Mix track; editors still see all three.
        let audioInputs = [mixTrack.input, systemTrack.input] + [micTrack?.input].compactMap({ $0 })
        let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: mixTrack.input)
        if writer.canAdd(group) { writer.add(group) }

        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Pool for composited frames (available once writing has started).
    var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    var audioTracks: [AudioTrackWriter] { [mixTrack, systemTrack] + [micTrack].compactMap { $0 } }

    var failed: Error? { writer.status == .failed ? (writer.error ?? RecorderError.writer("failed")) : nil }

    /// Appends a frame at output index `index`. Returns false if the encoder was busy (frame skipped).
    @discardableResult
    func appendVideo(_ pixelBuffer: CVPixelBuffer, index: Int64) -> Bool {
        guard index > lastVideoIndex, writer.status == .writing else { return false }
        guard videoInput.isReadyForMoreMediaData else { return false }
        let pts = CMTime(value: index, timescale: CMTimeScale(fps))
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastVideoIndex = index
            return true
        }
        log.error("Video append failed: \(self.writer.error?.localizedDescription ?? "?", privacy: .public)")
        return false
    }

    func finish(endSeconds: Double) async throws {
        videoInput.markAsFinished()
        for t in audioTracks { t.input.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(seconds: endSeconds, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    func cancel() { writer.cancelWriting() }
}

enum RecorderError: LocalizedError {
    case writer(String)
    case noDisplay
    case noFrames
    case noWindow
    case windowClosed
    case lowDisk
    case capture(String)

    var errorDescription: String? {
        switch self {
        case .writer(let s): return "Could not write the recording: \(s)"
        case .noDisplay: return "The selected display is not available."
        case .noFrames: return "No video arrived from the screen. Check the Screen Recording permission."
        case .noWindow: return "The selected window is no longer open. Choose another window."
        case .lowDisk: return "Less than 2 GB of disk space is free, so recording was stopped or not started. Free some space, choose another folder, or lower the resolution."
        case .windowClosed: return "The recorded window was closed. The recording up to that moment has been saved."
        case .capture(let s): return "Capture failed: \(s)"
        }
    }
}

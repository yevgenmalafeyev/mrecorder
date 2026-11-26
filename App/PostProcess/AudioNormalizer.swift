import AVFoundation
import RecorderCore

/// Post-stop loudness pass (EBU R128). Measures the System and Microphone tracks, then rebuilds
/// the Mix track with per-source gains (each to about -18 LUFS) and a final gain (mix to -16 LUFS),
/// limited to -1 dBFS. Video, System and Microphone tracks are copied untouched.
enum AudioNormalizer {
    enum Failure: LocalizedError {
        case layout(String), read(String), write(String)
        var errorDescription: String? {
            switch self {
            case .layout(let s): return "Unexpected track layout: \(s)"
            case .read(let s): return "Could not read the recording: \(s)"
            case .write(let s): return "Could not write the levelled recording: \(s)"
            }
        }
    }

    /// Audio tracks in writing order: Mix, System, Microphone (optional).
    struct Layout {
        let all: [AVAssetTrack]
        let mix: AVAssetTrack
        let system: AVAssetTrack
        let mic: AVAssetTrack?
    }

    static func layout(of asset: AVAsset) async throws -> Layout {
        let all = try await asset.load(.tracks).sorted { $0.trackID < $1.trackID }
        let audio = all.filter { $0.mediaType == .audio }
        guard audio.count >= 2 else { throw Failure.layout("\(audio.count) audio tracks") }
        return Layout(all: all, mix: audio[0], system: audio[1], mic: audio.count > 2 ? audio[2] : nil)
    }

    // MARK: - Measure

    static func analyze(_ url: URL) async throws -> (NormalizePlan, LoudnessAnalyzer) {
        let asset = AVURLAsset(url: url)
        let l = try await layout(of: asset)
        let reader = try AVAssetReader(asset: asset)
        let sources = try SourcePair(reader: reader, system: l.system, mic: l.mic)
        guard reader.startReading() else { throw Failure.read(reader.error?.localizedDescription ?? "?") }
        var analyzer = LoudnessAnalyzer(sampleRate: AudioInputConverter.sampleRate)
        while let (system, mic) = sources.next() {
            analyzer.add(system: system, mic: mic)
        }
        if reader.status == .failed { throw Failure.read(reader.error?.localizedDescription ?? "?") }
        return (NormalizePlan.compute(analyzer), analyzer)
    }

    // MARK: - Rewrite

    /// Rebuilds the Mix track of `url` with `plan` and replaces the file on success.
    static func apply(_ plan: NormalizePlan, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let l = try await layout(of: asset)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.deletingPathExtension().lastPathComponent + " levelling." + url.pathExtension)
        try? FileManager.default.removeItem(at: tmp)

        let copyReader = try AVAssetReader(asset: asset)
        let decodeReader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = false

        // Every track except the old Mix is copied as is (samples are not re-encoded).
        var copies: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var mixInput: AVAssetWriterInput?
        var mixTrack: AudioTrackWriter?
        var audioInputs: [AVAssetWriterInput] = []
        let mixIsPCM = try await isPCM(l.mix)
        for track in l.all {
            if track == l.mix {
                let t = AudioTrackWriter(name: "Mix", channels: 2, bitrate: 160_000, enabled: true,
                                         pcm: mixIsPCM, realTime: false)
                guard writer.canAdd(t.input) else { throw Failure.write("cannot add Mix") }
                writer.add(t.input)
                mixTrack = t
                mixInput = t.input
                audioInputs.append(t.input)
                continue
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            guard copyReader.canAdd(out) else { throw Failure.read("cannot read track \(track.trackID)") }
            copyReader.add(out)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            if let lang = try await track.load(.languageCode) { input.languageCode = lang }
            guard writer.canAdd(input) else { throw Failure.write("cannot add track \(track.trackID)") }
            writer.add(input)
            copies.append((out, input))
            if track.mediaType == .audio { audioInputs.append(input) }
        }
        guard let mixTrack, let mixInput else { throw Failure.layout("no Mix track") }
        // Same alternate group as the original: players use Mix; editors see all three.
        let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: mixInput)
        if writer.canAdd(group) { writer.add(group) }

        let sources = try SourcePair(reader: decodeReader, system: l.system, mic: l.mic)
        guard copyReader.startReading(), decodeReader.startReading() else {
            throw Failure.read((copyReader.error ?? decodeReader.error)?.localizedDescription ?? "?")
        }
        guard writer.startWriting() else { throw Failure.write(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)

        let group2 = DispatchGroup()
        for (i, (out, input)) in copies.enumerated() {
            group2.enter()
            let queue = DispatchQueue(label: "normalize.copy.\(i)")
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                while !done, input.isReadyForMoreMediaData {
                    if let sample = out.copyNextSampleBuffer() {
                        if !input.append(sample) { done = true }
                    } else {
                        done = true
                    }
                    if done {
                        input.markAsFinished()
                        group2.leave()
                    }
                }
            }
        }

        group2.enter()
        var mixer = Mixer()
        var sourcesDone = false
        var mixDone = false
        let chunk = 4800
        mixInput.requestMediaDataWhenReady(on: DispatchQueue(label: "normalize.mix")) {
            while !mixDone, mixInput.isReadyForMoreMediaData {
                if !sourcesDone, mixTrack.pendingFrames < chunk {
                    if let (system, mic) = sources.next() {
                        mixTrack.enqueue(mixer.mix(system: system, mic: mic, systemGain: plan.systemGain,
                                                   micGain: plan.micGain, outputGain: plan.mixGain))
                    } else {
                        sourcesDone = true
                    }
                    continue
                }
                mixTrack.drain(all: sourcesDone)
                if sourcesDone, mixTrack.pendingFrames == 0 {
                    mixDone = true
                    mixInput.markAsFinished()
                    group2.leave()
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group2.notify(queue: .global()) { c.resume() }
        }

        let readFailure = [copyReader, decodeReader].first { $0.status == .failed }?.error
        if let readFailure {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.read(readFailure.localizedDescription)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.write(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func isPCM(_ track: AVAssetTrack) async throws -> Bool {
        guard let desc = try await track.load(.formatDescriptions).first else { return false }
        return CMFormatDescriptionGetMediaSubType(desc) == kAudioFormatLinearPCM
    }
}

/// Decodes the System (stereo) and Microphone (mono) tracks to 48 kHz float and hands them out
/// in equal-length chunks. A track that ends early is padded with silence.
private final class SourcePair {
    private let system: PCMTrackReader
    private let mic: PCMTrackReader?

    init(reader: AVAssetReader, system: AVAssetTrack, mic: AVAssetTrack?) throws {
        self.system = try PCMTrackReader(reader: reader, track: system, channels: 2)
        self.mic = try mic.map { try PCMTrackReader(reader: reader, track: $0, channels: 1) }
    }

    func next(chunk: Int = 4800) -> (PlanarAudio, [Float]?)? {
        system.fill(chunk)
        mic?.fill(chunk)
        let n = min(chunk, max(system.available, mic?.available ?? 0))
        guard n > 0 else { return nil }
        let s = system.pop(n)
        let m = mic.map { $0.pop(n)[0] }
        return (s, m)
    }
}

private final class PCMTrackReader {
    private let output: AVAssetReaderTrackOutput
    private var fifo: AudioFIFO
    private let channels: Int
    private var ended = false

    init(reader: AVAssetReader, track: AVAssetTrack, channels: Int) throws {
        self.channels = channels
        fifo = AudioFIFO(channels: channels)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioInputConverter.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioNormalizer.Failure.read("cannot decode track \(track.trackID)") }
        reader.add(output)
    }

    var available: Int { fifo.count }

    func fill(_ frames: Int) {
        while !ended, fifo.count < frames {
            guard let sample = output.copyNextSampleBuffer() else {
                ended = true
                return
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            let n = interleaved.count / channels
            var planar = PlanarAudioUtil.silence(channels: channels, frames: n)
            for c in 0..<channels {
                var i = c
                for f in 0..<n {
                    planar[c][f] = interleaved[i]
                    i += channels
                }
            }
            fifo.append(planar)
        }
    }

    /// Pops `frames` frames, padding with silence once the track has ended.
    func pop(_ frames: Int) -> PlanarAudio {
        var out = fifo.pop(frames)
        let missing = frames - PlanarAudioUtil.frameCount(out)
        if missing > 0 {
            for c in 0..<channels { out[c].append(contentsOf: [Float](repeating: 0, count: missing)) }
        }
        return out
    }
}

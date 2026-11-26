import AVFoundation
import CoreMedia
import RecorderCore

/// Converts captured audio sample buffers of any format into planar Float32 at 48 kHz
/// with a fixed channel count. The converter is rebuilt when the input format changes
/// (Bluetooth profile switch, device change), so the output never plays at the wrong speed.
final class AudioInputConverter {
    static let sampleRate: Double = 48_000

    let channels: Int
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(channels: Int) {
        self.channels = channels
        target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
    }

    /// Returns the converted audio and the host time (seconds) of its first sample.
    func convert(_ sampleBuffer: CMSampleBuffer) -> (start: Double, audio: PlanarAudio)? {
        guard sampleBuffer.isValid,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
        )
        guard status == noErr else {
            log.error("Audio copy failed: \(status)")
            return nil
        }

        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if format == target { return (start, extract(input)) }

        if inputFormat != format || converter == nil {
            converter = AVAudioConverter(from: format, to: target)
            converter?.downmix = true
            inputFormat = format
            log.info("Audio converter: \(format.description, privacy: .public) -> \(self.channels) ch 48 kHz")
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if result == .error {
            log.error("Audio conversion failed: \(error?.localizedDescription ?? "?", privacy: .public)")
            return nil
        }
        return (start, extract(output))
    }

    private func extract(_ buffer: AVAudioPCMBuffer) -> PlanarAudio {
        let n = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            return PlanarAudioUtil.silence(channels: channels, frames: n)
        }
        let available = Int(buffer.format.channelCount)
        return (0..<channels).map { c in
            Array(UnsafeBufferPointer(start: data[min(c, available - 1)], count: n))
        }
    }
}

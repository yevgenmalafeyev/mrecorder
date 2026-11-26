import Foundation

/// Turns timestamped audio chunks into one continuous stream on the output timeline.
///
/// Frame 0 of the output timeline is the recording anchor. Each chunk says where its first
/// sample belongs (`startFrame`, may be negative for audio captured before the anchor).
/// Small jitter (within `tolerance`) is ignored and samples are laid back to back.
/// Larger gaps are filled with silence, larger overlaps are dropped. The same rule absorbs
/// slow clock drift between devices.
public struct TimelineAligner {
    public let channels: Int
    public let tolerance: Int64
    /// Number of frames emitted so far, i.e. the output position of the next frame.
    public private(set) var written: Int64 = 0

    public init(channels: Int, sampleRate: Double = 48_000, toleranceSeconds: Double = 0.02) {
        self.channels = channels
        self.tolerance = Int64(sampleRate * toleranceSeconds)
    }

    public mutating func ingest(startFrame: Int64, samples: PlanarAudio) -> PlanarAudio {
        let count = PlanarAudioUtil.frameCount(samples)
        guard count > 0 else { return PlanarAudioUtil.silence(channels: channels, frames: 0) }
        let drift = startFrame - written

        if drift > tolerance {
            // Gap: fill with silence up to the chunk start, then the chunk.
            var out = PlanarAudioUtil.silence(channels: channels, frames: Int(drift))
            for c in 0..<channels { out[c].append(contentsOf: samples[c]) }
            written += drift + Int64(count)
            return out
        }

        var skip = 0
        if drift < -tolerance {
            // Overlap: this audio is already covered (or is before the anchor). Drop the overlap.
            skip = Int(min(Int64(count), -drift))
        }
        let kept = count - skip
        guard kept > 0 else { return PlanarAudioUtil.silence(channels: channels, frames: 0) }
        written += Int64(kept)
        return samples.map { Array($0[skip...]) }
    }

    /// Emits silence so that `written` reaches `frame`, if it is behind.
    /// Used when a source stops delivering (silent system audio, unplugged mic).
    public mutating func padSilence(upTo frame: Int64) -> PlanarAudio {
        let missing = frame - written
        guard missing > 0 else { return PlanarAudioUtil.silence(channels: channels, frames: 0) }
        written = frame
        return PlanarAudioUtil.silence(channels: channels, frames: Int(missing))
    }
}

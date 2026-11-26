import Foundation

/// Mixes stereo system audio with mono microphone audio and applies a simple peak limiter.
public struct Mixer {
    /// Linear ceiling, -1 dBFS.
    public let ceiling: Float
    private let release: Float
    private var gain: Float = 1

    public init(ceilingDB: Float = -1, sampleRate: Float = 48_000, releaseSeconds: Float = 0.25) {
        ceiling = powf(10, ceilingDB / 20)
        release = 1 - expf(-1 / (sampleRate * releaseSeconds))
    }

    /// `system` is stereo planar; `mic` is mono (or nil). Both must have the same frame count.
    /// Optional gains: `systemGain`/`micGain` per source, `outputGain` on the sum (before the limiter).
    public mutating func mix(system: PlanarAudio, mic: [Float]?,
                             systemGain: Float = 1, micGain: Float = 1, outputGain: Float = 1) -> PlanarAudio {
        let frames = PlanarAudioUtil.frameCount(system)
        var left = system[0]
        var right = system.count > 1 ? system[1] : system[0]
        let gs = systemGain * outputGain, gm = micGain * outputGain
        if gs != 1 {
            for i in 0..<frames {
                left[i] *= gs
                right[i] *= gs
            }
        }
        if let mic {
            precondition(mic.count == frames, "frame count mismatch")
            for i in 0..<frames {
                left[i] += mic[i] * gm
                right[i] += mic[i] * gm
            }
        }
        for i in 0..<frames {
            let peak = max(abs(left[i]), abs(right[i]))
            let needed: Float = peak * gain > ceiling ? ceiling / peak : 1
            if needed < gain {
                gain = needed // instant attack
            } else {
                gain += (min(needed, 1) - gain) * release
            }
            left[i] *= gain
            right[i] *= gain
        }
        return [left, right]
    }
}

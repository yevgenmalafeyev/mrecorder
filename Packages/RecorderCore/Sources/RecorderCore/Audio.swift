import Foundation

/// Planar float audio: one array per channel, all the same length.
public typealias PlanarAudio = [[Float]]

public enum PlanarAudioUtil {
    public static func silence(channels: Int, frames: Int) -> PlanarAudio {
        Array(repeating: Array(repeating: 0, count: max(0, frames)), count: channels)
    }

    public static func frameCount(_ audio: PlanarAudio) -> Int { audio.first?.count ?? 0 }

    /// Interleaves planar audio into one array (L R L R ...).
    public static func interleave(_ audio: PlanarAudio) -> [Float] {
        let channels = audio.count
        let frames = frameCount(audio)
        guard channels > 1 else { return audio.first ?? [] }
        var out = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels {
            let src = audio[c]
            var i = c
            for f in 0..<frames {
                out[i] = src[f]
                i += channels
            }
        }
        return out
    }
}

/// A first-in first-out queue of planar audio frames.
public struct AudioFIFO {
    public let channels: Int
    private var storage: PlanarAudio
    private var head = 0

    public init(channels: Int) {
        self.channels = channels
        storage = Array(repeating: [], count: channels)
    }

    public var count: Int { (storage.first?.count ?? 0) - head }

    public mutating func append(_ audio: PlanarAudio) {
        precondition(audio.count == channels, "channel mismatch")
        for c in 0..<channels { storage[c].append(contentsOf: audio[c]) }
    }

    /// Removes and returns up to `frames` frames.
    public mutating func pop(_ frames: Int) -> PlanarAudio {
        let n = min(frames, count)
        var out: PlanarAudio = []
        out.reserveCapacity(channels)
        for c in 0..<channels { out.append(Array(storage[c][head..<(head + n)])) }
        head += n
        // Compact occasionally so memory does not grow without bound.
        if head > 48_000 {
            for c in 0..<channels { storage[c].removeFirst(head) }
            head = 0
        }
        return out
    }
}

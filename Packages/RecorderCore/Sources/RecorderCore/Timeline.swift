import Foundation

/// Maps capture (host) time in seconds to output time, cutting out paused spans.
///
/// Every timestamp maps exactly, even audio that arrives late from before a pause,
/// because all past pauses are kept as intervals.
public struct Timeline: Sendable {
    public let anchor: Double
    public private(set) var pauses: [ClosedRange<Double>] = []
    public private(set) var pausedAt: Double?

    public init(anchor: Double) { self.anchor = anchor }

    public var isPaused: Bool { pausedAt != nil }

    public var totalPaused: Double { pauses.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    /// Output seconds for a capture time, or nil if that moment was paused (or is before the anchor).
    public func outputSeconds(host t: Double) -> Double? {
        if let p = pausedAt, t >= p { return nil }
        var paused = 0.0
        for r in pauses {
            if t >= r.upperBound { paused += r.upperBound - r.lowerBound }
            else if t >= r.lowerBound { return nil }
            else { break }
        }
        return t - anchor - paused
    }

    /// Like `outputSeconds`, but a moment inside a pause maps to where the pause started.
    /// Use for "how far has the recording got" (timers, frame targets, stop time).
    public func outputSecondsClamped(host t: Double) -> Double {
        var t = t
        if let p = pausedAt, t > p { t = p }
        var paused = 0.0
        for r in pauses {
            if t >= r.upperBound { paused += r.upperBound - r.lowerBound }
            else if t > r.lowerBound { t = r.lowerBound; break }
            else { break }
        }
        return max(0, t - anchor - paused)
    }

    /// Capture time that corresponds to an output time (inverse of `outputSeconds`).
    public func hostTime(output o: Double) -> Double {
        var host = anchor + o
        for r in pauses where host >= r.lowerBound {
            host += r.upperBound - r.lowerBound
        }
        return host
    }

    public mutating func pause(at host: Double) {
        guard pausedAt == nil else { return }
        pausedAt = max(host, pauses.last?.upperBound ?? anchor)
    }

    public mutating func resume(at host: Double) {
        guard let p = pausedAt else { return }
        pauses.append(p...max(p, host))
        pausedAt = nil
    }
}

/// Output frame index helpers for a constant frame rate.
public enum FrameGrid {
    /// Highest frame index whose time is at or before `seconds`.
    public static func lastIndex(atOrBefore seconds: Double, fps: Int) -> Int64 {
        Int64((seconds * Double(fps)).rounded(.down))
    }

    /// Even dimension, as video encoders require.
    public static func even(_ value: Double) -> Int {
        let v = Int(value.rounded())
        return v - (v % 2)
    }
}

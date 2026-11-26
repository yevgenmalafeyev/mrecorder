import Foundation

/// Second-order IIR filter (direct form II transposed), Double precision state.
public struct Biquad {
    var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// ITU-R BS.1770 K-weighting: high shelf + high pass, for any sample rate.
/// Filter constants as published in libebur128 (MIT, https://github.com/jiixyj/libebur128).
public struct KWeighting {
    private var shelf: Biquad
    private var highPass: Biquad

    public init(sampleRate: Double) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let g = 3.999843853973347
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                       b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Double { highPass.process(shelf.process(Double(x))) }
}

/// Measures the integrated loudness (BS.1770-4 / EBU R128) of system audio, microphone audio,
/// and of their mix for any pair of gains, in one pass.
///
/// K-weighting is linear, so for every 100 ms sub-block it keeps the energies of the weighted
/// system channels and mic plus their cross terms. The mix `gs*system + gm*mic` (mic on both channels,
/// as in `Mixer`) then has energy `gs²·S + gm²·M + 2·gs·gm·X` per channel, exactly.
public struct LoudnessAnalyzer {
    struct SubBlock { var sL = 0.0, sR = 0.0, m = 0.0, xL = 0.0, xR = 0.0 }

    public let sampleRate: Double
    private let subBlockFrames: Int
    private var kL, kR, kM: KWeighting
    private var current = SubBlock()
    private var currentFrames = 0
    private var subBlocks: [SubBlock] = []

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        subBlockFrames = Int(sampleRate / 10)
        kL = KWeighting(sampleRate: sampleRate)
        kR = KWeighting(sampleRate: sampleRate)
        kM = KWeighting(sampleRate: sampleRate)
    }

    /// `system`: stereo planar (mono is used for both channels). `mic`: mono, same frame count, or nil.
    public mutating func add(system: PlanarAudio, mic: [Float]?) {
        let frames = PlanarAudioUtil.frameCount(system)
        let left = system[0]
        let right = system.count > 1 ? system[1] : system[0]
        for i in 0..<frames {
            let l = kL.process(left[i]), r = kR.process(right[i])
            let m = mic.map { kM.process($0[i]) } ?? 0
            current.sL += l * l
            current.sR += r * r
            current.m += m * m
            current.xL += l * m
            current.xR += r * m
            currentFrames += 1
            if currentFrames == subBlockFrames {
                subBlocks.append(current)
                current = SubBlock()
                currentFrames = 0
            }
        }
    }

    /// Integrated loudness of the stereo system audio, in LUFS (nil if silent).
    public var systemLoudness: Double? { integrated { $0.sL + $0.sR } }

    /// Integrated loudness of the microphone as a mono programme, in LUFS (nil if silent).
    public var micLoudness: Double? { integrated { $0.m } }

    /// Integrated loudness of the stereo mix `systemGain*system + micGain*mic` (before any limiting).
    public func mixLoudness(systemGain gs: Double, micGain gm: Double) -> Double? {
        integrated { b in
            gs * gs * (b.sL + b.sR) + 2 * gm * gm * b.m + 2 * gs * gm * (b.xL + b.xR)
        }
    }

    /// Gated integrated loudness from per-sub-block summed channel energy.
    private func integrated(_ energy: (SubBlock) -> Double) -> Double? {
        guard subBlocks.count >= 4 else { return nil }
        let e = subBlocks.map(energy)
        let blockFrames = Double(subBlockFrames * 4)
        // 400 ms blocks, 75% overlap.
        var powers: [Double] = []
        powers.reserveCapacity(e.count - 3)
        var sum = e[0] + e[1] + e[2]
        for j in 3..<e.count {
            sum += e[j]
            powers.append(sum / blockFrames)
            sum -= e[j - 3]
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(p) }
        let absGated = powers.filter { $0 > 0 && lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relGate = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// Gains that even out the mixed track: each source to about -18 LUFS, the mix to -16 LUFS.
public struct NormalizePlan: Equatable, Sendable {
    public var systemGain: Float
    public var micGain: Float
    /// Applied after mixing, before the -1 dBFS limiter.
    public var mixGain: Float

    public static let sourceTarget = -18.0
    public static let mixTarget = -16.0
    /// Sources quieter than this are treated as silence or noise and left alone.
    public static let silenceFloor = -50.0
    public static let maxBoostDB = 20.0
    public static let maxCutDB = 20.0

    public init(systemGain: Float, micGain: Float, mixGain: Float) {
        (self.systemGain, self.micGain, self.mixGain) = (systemGain, micGain, mixGain)
    }

    public static func compute(_ a: LoudnessAnalyzer) -> NormalizePlan {
        func sourceGain(_ l: Double?) -> Double {
            guard let l, l > silenceFloor else { return 1 }
            let db = min(maxBoostDB, max(-maxCutDB, sourceTarget - l))
            return pow(10, db / 20)
        }
        let gs = sourceGain(a.systemLoudness)
        let gm = sourceGain(a.micLoudness)
        var mix = 1.0
        if let l = a.mixLoudness(systemGain: gs, micGain: gm), l > silenceFloor {
            mix = pow(10, min(maxBoostDB, max(-maxCutDB, mixTarget - l)) / 20)
        }
        return NormalizePlan(systemGain: Float(gs), micGain: Float(gm), mixGain: Float(mix))
    }

    public var isIdentity: Bool { systemGain == 1 && micGain == 1 && mixGain == 1 }
}

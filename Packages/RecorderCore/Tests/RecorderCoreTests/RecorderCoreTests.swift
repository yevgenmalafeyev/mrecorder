import CoreGraphics
import Testing
@testable import RecorderCore

@Suite struct TimelineAlignerTests {
    @Test func contiguousChunksPassThrough() {
        var a = TimelineAligner(channels: 1)
        let out1 = a.ingest(startFrame: 0, samples: [[1, 2, 3]])
        let out2 = a.ingest(startFrame: 3, samples: [[4, 5]])
        #expect(out1 == [[1, 2, 3]])
        #expect(out2 == [[4, 5]])
        #expect(a.written == 5)
    }

    @Test func smallJitterIsIgnored() {
        var a = TimelineAligner(channels: 1) // tolerance 960 frames
        _ = a.ingest(startFrame: 0, samples: [[Float](repeating: 1, count: 100)])
        let out = a.ingest(startFrame: 500, samples: [[2, 2]]) // 400 frames late, within tolerance
        #expect(out == [[2, 2]])
        #expect(a.written == 102)
    }

    @Test func largeGapIsFilledWithSilence() {
        var a = TimelineAligner(channels: 2)
        _ = a.ingest(startFrame: 0, samples: [[1], [1]])
        let out = a.ingest(startFrame: 2001, samples: [[7], [7]])
        #expect(out[0].count == 2001)
        #expect(out[0].last == 7)
        #expect(out[0][0] == 0)
        #expect(a.written == 2002)
    }

    @Test func preAnchorAudioIsTrimmed() {
        var a = TimelineAligner(channels: 1)
        let chunk = (0..<3000).map { Float($0) }
        let out = a.ingest(startFrame: -2000, samples: [chunk])
        #expect(out[0].count == 1000)
        #expect(out[0].first == 2000)
        #expect(a.written == 1000)
    }

    @Test func overlapAfterPaddingIsDropped() {
        var a = TimelineAligner(channels: 1)
        _ = a.padSilence(upTo: 4800)
        let out = a.ingest(startFrame: 2400, samples: [[Float](repeating: 1, count: 4800)])
        #expect(out[0].count == 2400)
        #expect(a.written == 7200)
    }
}

@Suite struct MixerTests {
    @Test func mixesAndLimits() {
        var m = Mixer()
        let out = m.mix(system: [[0.8, 0.1], [0.8, 0.1]], mic: [0.8, 0.1])
        #expect(out[0][0] <= m.ceiling + 1e-6)
        #expect(out[1][0] <= m.ceiling + 1e-6)
    }

    @Test func quietSignalUnchanged() {
        var m = Mixer()
        let out = m.mix(system: [[0.1], [0.2]], mic: [0.1])
        #expect(abs(out[0][0] - 0.2) < 1e-6)
        #expect(abs(out[1][0] - 0.3) < 1e-6)
    }
}

@Suite struct FIFOAndTimelineTests {
    @Test func fifoPopsInOrder() {
        var f = AudioFIFO(channels: 2)
        f.append([[1, 2, 3], [4, 5, 6]])
        #expect(f.pop(2) == [[1, 2], [4, 5]])
        #expect(f.count == 1)
        #expect(f.pop(5) == [[3], [6]])
        #expect(f.count == 0)
    }

    @Test func interleave() {
        #expect(PlanarAudioUtil.interleave([[1, 2], [3, 4]]) == [1, 3, 2, 4])
    }

    @Test func pauseExcludesGap() {
        var t = Timeline(anchor: 100)
        t.pause(at: 110)
        #expect(t.outputSeconds(host: 105) == 5)
        #expect(t.outputSeconds(host: 125) == nil)          // inside the pause
        #expect(t.outputSecondsClamped(host: 125) == 10)    // frozen while paused
        t.resume(at: 130)
        #expect(t.outputSeconds(host: 135) == 15)
        #expect(t.outputSeconds(host: 109) == 9)            // late audio from before the pause
        #expect(t.outputSeconds(host: 120) == nil)
        #expect(t.outputSecondsClamped(host: 120) == 10)
        #expect(t.hostTime(output: 9) == 109)
        #expect(t.hostTime(output: 15) == 135)
    }

    @Test func multiplePauses() {
        var t = Timeline(anchor: 0)
        t.pause(at: 10); t.resume(at: 20)   // 10 s paused
        t.pause(at: 30); t.resume(at: 35)   // 5 s paused
        #expect(t.totalPaused == 15)
        #expect(t.outputSeconds(host: 40) == 25)
        #expect(t.outputSeconds(host: 25) == 15)
        #expect(t.hostTime(output: 25) == 40)
        #expect(t.hostTime(output: 15) == 25)
        #expect(t.hostTime(output: 5) == 5)
    }

    @Test func frameGrid() {
        #expect(FrameGrid.lastIndex(atOrBefore: 1.0, fps: 30) == 30)
        #expect(FrameGrid.even(1215.4) == 1214)
        #expect(FrameGrid.even(3840) == 3840)
    }
}

@Suite struct OverlayGeometryTests {
    let canvas = CGSize(width: 3840, height: 2160)

    @Test func circleBottomRight() {
        let r = OverlayGeometry.rect(canvas: canvas, config: OverlayConfig(shape: .circle, corner: .bottomRight, size: 0.2))
        #expect(r.width == 432 && r.height == 432)
        #expect(r.maxX == CGFloat(3786))
        #expect(r.minY == 54)
    }

    @Test func rectangleTopLeft() {
        let r = OverlayGeometry.rect(canvas: canvas, config: OverlayConfig(shape: .rectangle, corner: .topLeft, size: 0.2))
        #expect(r.height == 432 && r.width == 768)
        #expect(r.minX == 54)
        #expect(r.maxY == CGFloat(2106))
    }

    @Test func portraitUsesShortSide() {
        let r = OverlayGeometry.rect(canvas: CGSize(width: 1080, height: 1920), config: OverlayConfig(size: 0.2))
        #expect(r.height == 216)
    }

    @Test func aspectCrop() {
        let c = OverlayGeometry.aspectCrop(source: CGSize(width: 1280, height: 720), target: CGSize(width: 1, height: 1))
        #expect(c == CGRect(x: 280, y: 0, width: 720, height: 720))
    }
}

@Suite struct CanvasLayoutTests {
    @Test func landscapePlusPortrait() {
        let l = CanvasLayout.sideBySide(sources: [CGSize(width: 3840, height: 2160), CGSize(width: 1890, height: 3360)], height: 2160)
        #expect(l.canvas == CGSize(width: 3840 + 1214, height: 2160))
        #expect(l.slots[0] == CGRect(x: 0, y: 0, width: 3840, height: 2160))
        #expect(l.slots[1] == CGRect(x: 3840, y: 0, width: 1214, height: 2160))
    }

    @Test func cappedHeight() {
        let l = CanvasLayout.sideBySide(sources: [CGSize(width: 3840, height: 2160), CGSize(width: 1890, height: 3360)], height: 1080)
        #expect(l.canvas == CGSize(width: 1920 + 608, height: 1080))
    }

    @Test func noUpscalePastTallest() {
        let l = CanvasLayout.sideBySide(sources: [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)], height: 2160)
        #expect(l.canvas.height == 1080)
    }

    @Test func capShortSide() {
        #expect(CanvasLayout.capped(CGSize(width: 1890, height: 3360), maxShortSide: 1080) == CGSize(width: 1080, height: 1920))
        #expect(CanvasLayout.capped(CGSize(width: 3840, height: 2160), maxShortSide: 0) == CGSize(width: 3840, height: 2160))
    }

    @Test func aspectFitCenters() {
        let r = CanvasLayout.aspectFit(CGSize(width: 100, height: 50), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(r == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func h264Limit() {
        let l = CanvasLayout.sideBySide(sources: [CGSize(width: 3840, height: 2160), CGSize(width: 1890, height: 3360)],
                                        height: 2160, maxDimension: 4096)
        #expect(l.canvas.width <= 4096)
        #expect(l.canvas.height < 2160)
        #expect(CanvasLayout.fit(CGSize(width: 5000, height: 2000), maxDimension: 4096) == CGSize(width: 4096, height: 1638))
        #expect(CanvasLayout.fit(CGSize(width: 1890, height: 3360), maxDimension: 4096) == CGSize(width: 1890, height: 3360))
    }

    @Test func overlayTarget() {
        #expect(CanvasLayout.overlayTarget(corner: .bottomLeft, count: 2) == 0)
        #expect(CanvasLayout.overlayTarget(corner: .topRight, count: 2) == 1)
        #expect(CanvasLayout.overlayTarget(corner: .topRight, count: 1) == 0)
    }
}

@Suite struct LoudnessTests {
    func sine(_ amp: Float, seconds: Double = 5, freq: Float = 997) -> [Float] {
        (0..<Int(48_000 * seconds)).map { amp * sinf(2 * .pi * freq * Float($0) / 48_000) }
    }

    @Test func stereoSineReference() throws {
        // BS.1770: a 997 Hz sine at -20 dBFS on both channels reads -20 LUFS.
        var a = LoudnessAnalyzer()
        let s = sine(0.1)
        a.add(system: [s, s], mic: nil)
        let l = try #require(a.systemLoudness)
        #expect(abs(l - -20) < 0.1)
        #expect(a.micLoudness == nil)
    }

    @Test func monoMicReference() throws {
        // One channel only: -3.01 dB lower.
        var a = LoudnessAnalyzer()
        let s = sine(0.1)
        a.add(system: PlanarAudioUtil.silence(channels: 2, frames: s.count), mic: s)
        let l = try #require(a.micLoudness)
        #expect(abs(l - -23.01) < 0.1)
    }

    @Test func mixFormulaMatchesRealMix() throws {
        // Speech-like alternation: system tone first, then mic tone, with some overlap.
        let n = 48_000 * 6
        var sys = [Float](repeating: 0, count: n), mic = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / 48_000
            if t < 4 { sys[i] = 0.05 * sinf(2 * .pi * 300 * t) }
            if t > 2.5 { mic[i] = 0.3 * sinf(2 * .pi * 1200 * t) }
        }
        var a = LoudnessAnalyzer()
        // Feed in odd chunk sizes to exercise sub-block boundaries.
        var pos = 0
        while pos < n {
            let k = min(3_333, n - pos)
            a.add(system: [Array(sys[pos..<pos + k]), Array(sys[pos..<pos + k])], mic: Array(mic[pos..<pos + k]))
            pos += k
        }
        let gs = 2.5, gm = 0.4
        let mixed = (0..<n).map { Float(gs) * sys[$0] + Float(gm) * mic[$0] }
        var b = LoudnessAnalyzer()
        b.add(system: [mixed, mixed], mic: nil)
        let predicted = try #require(a.mixLoudness(systemGain: gs, micGain: gm))
        let actual = try #require(b.systemLoudness)
        #expect(abs(predicted - actual) < 0.01)
    }

    @Test func planEvensOutQuietSystemAndLeavesSilentMicAlone() throws {
        var a = LoudnessAnalyzer()
        let s = sine(0.01) // -40 LUFS
        a.add(system: [s, s], mic: [Float](repeating: 0, count: s.count))
        let p = NormalizePlan.compute(a)
        #expect(p.micGain == 1)
        #expect(abs(20 * log10(p.systemGain) - 20) < 0.2) // capped at +20 dB
        let final = try #require(a.mixLoudness(systemGain: Double(p.systemGain * p.mixGain), micGain: 0))
        #expect(abs(final - NormalizePlan.mixTarget) < 0.1)
    }

    @Test func silenceIsIdentity() {
        var a = LoudnessAnalyzer()
        a.add(system: PlanarAudioUtil.silence(channels: 2, frames: 96_000), mic: [Float](repeating: 0, count: 96_000))
        #expect(NormalizePlan.compute(a).isIdentity)
    }

    @Test func mixerAppliesGains() {
        var m = Mixer()
        let out = m.mix(system: [[0.1], [0.1]], mic: [0.1], systemGain: 2, micGain: 1, outputGain: 0.5)
        #expect(abs(out[0][0] - 0.15) < 1e-6)
    }
}

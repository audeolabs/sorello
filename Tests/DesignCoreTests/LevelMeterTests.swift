import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "Listening": the level follows the speaker's own range. Ported with the iPhone app's
/// tests and numbers; every buffer is 100 ms of invented tone or hiss.
@Suite struct LevelMeterTests {
    static func tone(_ count: Int, amplitude: Float) -> [Float] {
        (0 ..< count).map { amplitude * sinf(Float($0) * 0.2) }
    }

    /// 100 ms of a tone whose RMS is `dBFS`.
    static func buffer(at dBFS: Double) -> [Float] {
        tone(1_600, amplitude: Float(2.0.squareRoot() * pow(10, dBFS / 20)))
    }

    /// 100 ms of invented room noise (a fixed pseudo-random hiss) whose RMS is `dBFS`.
    static func noise(at dBFS: Double, seed: inout UInt64) -> [Float] {
        let amplitude = Float(3.0.squareRoot() * pow(10, dBFS / 20))
        return (0 ..< 1_600).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// Invented speech at `dBFS`: syllables a little above it with 100 ms gaps 18 dB down between them, for
    /// `seconds`. Returns the level after each buffer.
    static func speak(_ meter: inout LevelMeter, at dBFS: Double, seconds: Double) -> [Float] {
        let pattern = [dBFS + 3, dBFS + 1, dBFS - 18]
        return (0 ..< Int(seconds * 10)).map { index in
            meter.update(with: buffer(at: pattern[index % pattern.count]))
            return meter.level
        }
    }

    @Test func levelTracksSpeechAndStaysInRange() {
        var meter = LevelMeter()
        meter.update(with: [Float](repeating: 0, count: 1_600))
        #expect(meter.level == 0)
        var previous: Float = 0
        for _ in 0 ..< 6 {
            meter.update(with: Self.tone(1_600, amplitude: 0.3))
            #expect(meter.level > previous && meter.level <= 1)
            previous = meter.level
        }
        #expect(previous > 0.8)
        meter.update(with: Self.tone(1_600, amplitude: 0.001))
        #expect(meter.level < previous && meter.level > 0)
        meter.update(with: [Float](repeating: .nan, count: 160))
        #expect(meter.level.isFinite)
        meter.update(with: [Float](repeating: 10, count: 160))
        #expect(meter.level <= 1)
        meter.update(with: [Float]())
        meter.update(meanSquare: 0.1, count: 0)
        #expect(meter.level <= 1)
    }

    /// The level falls with a syllable's end, within two buffers, so the wave sees a gap between words; ordinary
    /// speech sits clearly below the top, so a louder word still shows louder.
    @Test func levelFollowsSyllables() {
        var meter = LevelMeter()
        for _ in 0 ..< 8 { meter.update(with: Self.tone(1_600, amplitude: 0.3)) }
        let speaking = meter.level
        meter.update(with: Self.tone(1_600, amplitude: 0.001))
        meter.update(with: Self.tone(1_600, amplitude: 0.001))
        #expect(meter.level <= 0.25 * speaking)
        for _ in 0 ..< 8 { meter.update(with: Self.tone(1_600, amplitude: 0.2)) }
        let ordinary = meter.level
        #expect(ordinary < 0.92)
        for _ in 0 ..< 8 { meter.update(with: Self.tone(1_600, amplitude: 0.5)) }
        #expect(meter.level > ordinary + 0.05)
    }

    /// A soft, a normal and a loud speaker (-32, -22 and -12 dBFS) all look clearly active from the first second:
    /// their syllables reach near the top, where the wave swells, and dip clearly between.
    @Test func softNormalAndLoudVoicesAllLookActive() throws {
        var peaks: [Float] = []
        for dBFS in [-32.0, -22, -12] {
            var meter = LevelMeter()
            let levels = Self.speak(&meter, at: dBFS, seconds: 3)
            let first = levels.prefix(10), all = levels.dropFirst(3)
            let firstPeak = try #require(first.max()), peak = try #require(all.max()), low = try #require(all.min())
            #expect(firstPeak >= 0.85, "a voice at \(dBFS) dBFS starts flat")
            #expect(peak >= 0.85, "a voice at \(dBFS) dBFS reads quiet")
            #expect(peak - low >= 0.35, "syllables at \(dBFS) dBFS blur together")
            #expect(DotWave.voice(Double(peak)) >= 0.75)
            peaks.append(peak)
        }
        #expect(try #require(peaks.min()) >= 0.85 * (try #require(peaks.max())))
    }

    /// Silence and a quiet room (invented hiss at -55 and -50 dBFS) rest flat: before anyone speaks, in a pause after
    /// a soft speaker, and long after a loud one. The wave draws nothing below its dead zone.
    @Test func roomNoiseAndPausesRestFlat() {
        var seed: UInt64 = 7
        for room in [-55.0, -50] {
            for speaker in [nil, -32.0, -12] {
                var meter = LevelMeter()
                for _ in 0 ..< 20 {
                    meter.update(with: Self.noise(at: room, seed: &seed))
                    if speaker == nil { #expect(meter.level <= 0.03) }
                }
                guard let speaker else { continue }
                _ = Self.speak(&meter, at: speaker, seconds: 2)
                var pause: [Float] = []
                for _ in 0 ..< 60 {
                    meter.update(with: Self.noise(at: room, seed: &seed))
                    pause.append(meter.level)
                }
                #expect(pause.dropFirst(3).allSatisfy { DotWave.voice(Double($0)) == 0 })
                #expect(pause.dropFirst(3).allSatisfy { $0 <= 0.08 })
                #expect(pause.suffix(20).allSatisfy { $0 <= 0.03 })
            }
        }
    }

    /// One loud moment (-6 dBFS) shrinks what follows for a moment, as a louder word should, but ordinary words at
    /// -22 dBFS look active again within 3 s.
    @Test func aLoudMomentDoesNotSilenceTheNextWords() throws {
        var meter = LevelMeter()
        _ = Self.speak(&meter, at: -22, seconds: 1)
        meter.update(with: Self.buffer(at: -6))
        meter.update(with: Self.buffer(at: -6))
        let next = Self.speak(&meter, at: -22, seconds: 3.6)
        #expect(try #require(next.prefix(4).max()) < 0.95)
        #expect(try #require(next.suffix(6).max()) >= 0.85)
    }

    /// Fed as a mean square and a length, a block reads exactly as the same samples do.
    @Test func aMeanSquareIsTheSameBlock() {
        var bySamples = LevelMeter(), bySums = LevelMeter()
        for amplitude: Float in [0.3, 0.01, 0.2, 0.5, 0.001] {
            let block = Self.tone(1_600, amplitude: amplitude)
            bySamples.update(with: block)
            bySums.update(meanSquare: block.map { $0 * $0 }.reduce(0, +) / 1_600, count: 1_600)
            #expect(abs(bySamples.level - bySums.level) < 1e-6)
        }
    }
}

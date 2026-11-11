import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "Listening" and "Waiting": the wave the pill holds while it listens, and the wait's
/// shimmer. Ported with the iPhone app's tests and numbers.
@Suite struct DotWaveTests {
    static let width = 90.0, height = 24.0

    /// A voice held at `level` for the whole row.
    static func held(_ level: Double, width: Double = width, height: Double = height) -> [DotWave.Dot] {
        DotWave.dots(level: level, width: width, height: height)
    }

    /// A trace of the voice as the pill records it, one level a frame at 60 frames a second: `level(t)` for t seconds
    /// from 0 to `until`, read through the follower.
    static func trace(until: Double, _ level: (Double) -> Double) -> DotWave.Trace {
        var trace = DotWave.Trace(), follower = DotWave.LevelFollower()
        for frame in 0 ... Int((until * 60).rounded()) {
            let t = Double(frame) / 60
            follower.follow(level(t), over: 1.0 / 60)
            trace.record(follower.value, at: t)
        }
        return trace
    }

    /// The wave is one row of dots along the middle line, evenly spaced, with no dim field around it, and its dots
    /// never touch, however loud.
    @Test func waveIsOneRowOfDots() {
        let speech = Self.trace(until: 2) { 0.5 + 0.5 * sin($0 * 9) }
        for dots in [Self.held(0), Self.held(0.5), Self.held(1),
                     DotWave.dots(trace: speech, now: 2, width: Self.width, height: Self.height)] {
            #expect(dots.count >= 10)
            #expect(dots.allSatisfy { abs($0.y - Self.height / 2) < 1e-9 })
            #expect(dots.allSatisfy { $0.brightness >= DotWave.restBrightness - 1e-9 })
            for (a, b) in zip(dots, dots.dropFirst()) {
                #expect(abs(b.x - a.x - DotWave.pitch) < 1e-9, "uneven spacing")
                #expect(b.x - a.x > a.radius + b.radius + 0.3, "dots touch")
            }
        }
    }

    /// The numbers the iPhone's island settled on: 6.2 pt apart, 1.4 to 2.85 pt radius, half to full brightness, the
    /// aurora dot 2.55 pt swelling by 35%, 0.75 s of voice, a 1.1 s sweep, at most 60 frames a second.
    @Test func keepsTheIslandsNumbers() {
        #expect(DotWave.pitch == 6.2)
        #expect(DotWave.restRadius == 1.4)
        #expect(DotWave.fullRadius == 2.85)
        #expect(DotWave.restBrightness == 0.5)
        #expect(DotWave.markRadius == 2.55)
        #expect(DotWave.markGrowth == 0.35)
        #expect(DotWave.span == 0.75)
        #expect(DotWave.shimmerPeriod == 1.1)
        #expect(DotWave.frameInterval == 1.0 / 60)
        #expect(DotWave.pitch > 2 * DotWave.fullRadius + 0.3)
        #expect(DotWave.fullRadius >= DotWave.restRadius * 2)
    }

    /// In silence the row rests: every dot the same size and brightness. A row that has heard nothing for its whole
    /// span is silent again, however loud it was before.
    @Test func silenceIsAFlatRowOfDots() {
        for level in [0, -2, .nan] {
            let dots = Self.held(level)
            #expect(!dots.isEmpty)
            #expect(dots.allSatisfy { abs($0.radius - DotWave.restRadius) < 1e-9 })
            #expect(dots.allSatisfy { abs($0.brightness - DotWave.restBrightness) < 1e-9 })
        }
        let afterwards = Self.trace(until: 3) { $0 < 1 ? 1 : 0 }
        let dots = DotWave.dots(trace: afterwards, now: 3, width: Self.width, height: Self.height)
        #expect(dots.allSatisfy { abs($0.radius - DotWave.restRadius) < 0.01 })
        #expect(DotWave.dots(trace: DotWave.Trace(), now: 5, width: Self.width, height: Self.height)
            .allSatisfy { abs($0.radius - DotWave.restRadius) < 1e-9 })
    }

    /// Loud and quiet look clearly different: a voice held loud swells the row at least twice as much as one held at
    /// half, full level is the whole swell, and bigger is brighter.
    @Test func louderSwellsTheRow() throws {
        func growth(_ dots: [DotWave.Dot]) -> Double { dots.map { $0.radius - DotWave.restRadius }.reduce(0, +) }
        let levels = [0, 0.25, 0.5, 0.75, 1.0].map { growth(Self.held($0)) }
        for (a, b) in zip(levels, levels.dropFirst()) { #expect(b >= a - 1e-9) }
        #expect(levels[4] >= 2 * levels[2])
        #expect(levels[2] > 0)
        let fullest = try #require(Self.held(1).map(\.radius).max())
        #expect(abs(fullest - DotWave.fullRadius) < 0.05)
        #expect(Self.held(3) == Self.held(1))
        func word(_ level: Double) -> [DotWave.Dot] {
            DotWave.dots(trace: Self.trace(until: 1) { $0 >= 0.6 && $0 < 0.8 ? level : 0 }, now: 1, width: Self.width,
                         height: Self.height)
        }
        let quiet = word(0.5), loud = word(1)
        #expect(growth(loud) > 2 * growth(quiet) && growth(quiet) > 0)
        for dots in [Self.held(1), loud] {
            let largest = try #require(dots.max { $0.radius < $1.radius })
            #expect(largest.brightness == dots.map(\.brightness).max())
            #expect(dots.allSatisfy { $0.brightness <= 1 && $0.radius <= DotWave.fullRadius + 1e-9 })
        }
    }

    /// The row's shape is the voice's own: the last `span` seconds, the newest beside the aurora dot; what was said
    /// moves away as it ages, crosses the row in about `span` and leaves it. The far end rises out of the line.
    @Test func theRowIsTheVoiceMovingAway() throws {
        func syllable(until now: Double) -> DotWave.Trace { Self.trace(until: now) { $0 >= 0.2 && $0 < 0.32 ? 1 : 0 } }
        func peak(at now: Double) -> Double {
            let dots = DotWave.dots(trace: syllable(until: now), now: now, width: Self.width, height: Self.height)
            guard let largest = dots.max(by: { $0.radius < $1.radius }) else { return -1 }
            return largest.radius > DotWave.restRadius + 0.3 ? largest.x : -1
        }
        let early = peak(at: 0.45), later = peak(at: 0.8)
        #expect(early > 0 && later > 0)
        #expect(early > later + 10)
        let row = Self.held(0).map(\.x)
        let length = try #require(row.max()) - (try #require(row.min()))
        let speed = (early - later) / 0.35
        #expect(abs(speed - length / DotWave.span) < length / DotWave.span * 0.35)
        #expect(peak(at: 0.26 + DotWave.span + 0.25) < 0)
        let loud = try #require(Self.held(1).first)
        #expect(loud.radius - DotWave.restRadius < (DotWave.fullRadius - DotWave.restRadius) / 2)
        #expect(DotWave.dots(trace: syllable(until: 0.5), now: 0.5, width: Self.width, height: Self.height)
            == DotWave.dots(trace: syllable(until: 0.5), now: 0.5, width: Self.width, height: Self.height))
    }

    /// Syllables read as distinct pulses: the level rises most of a jump within 50 ms and falls under a fifth within
    /// 0.2 s, never overshooting; two syllables 0.25 s apart show as two pulses with a dip between.
    @Test func syllablesAreDistinctPulses() {
        var follower = DotWave.LevelFollower()
        #expect(follower.value == 0)
        for _ in 0 ..< 3 { follower.follow(1, over: 1.0 / 60) }
        #expect(follower.value >= 0.8 && follower.value <= 1)
        for _ in 0 ..< 60 { follower.follow(1, over: 1.0 / 60) }
        for _ in 0 ..< 12 { follower.follow(0, over: 1.0 / 60) }
        #expect(follower.value <= 0.2 && follower.value >= 0)
        follower.follow(5, over: 10)
        #expect(follower.value <= 1)
        let held = follower.value
        follower.follow(0, over: 0)
        follower.follow(0, over: -1)
        #expect(follower.value == held)
        follower.follow(.nan, over: 10)
        #expect(follower.value >= 0 && follower.value < 0.01)
        follower.follow(0.5, over: .nan)
        #expect(follower.value.isFinite)
        let twoSyllables = Self.trace(until: 1) { t in
            let sample = (t * 10).rounded(.down) / 10
            return (sample >= 0.2 && sample < 0.3) || (sample >= 0.5 && sample < 0.6) ? 1 : 0.05
        }
        let lifts = (0 ... 40).map { DotWave.lift(at: 1 - Double($0) / 40 * 0.9, trace: twoSyllables, now: 0.75) }
        let dips = lifts.indices.filter { i in
            i > 0 && i < lifts.count - 1 && lifts[i] < lifts[i - 1] && lifts[i] <= lifts[i + 1]
        }
        #expect(lifts.contains { $0 > 0.35 })
        #expect(dips.contains { lifts[$0] < 0.6 * (lifts.max() ?? 0) })
    }

    /// Levels that arrive ten times a second draw a row whose neighbours differ by less than half the swell, and no
    /// dot changes size by more than a tenth of the swell from one 60 Hz frame to the next.
    @Test func tenLevelsASecondLookContinuous() {
        func steps(until now: Double) -> DotWave.Trace {
            Self.trace(until: now) { t in
                (t * 10).rounded(.down).truncatingRemainder(dividingBy: 3) == 0 ? 1 : 0.2
            }
        }
        let swell = DotWave.fullRadius - DotWave.restRadius
        var previous: [DotWave.Dot]?
        for frame in 0 ..< 60 {
            let now = 1.2 + Double(frame) / 60
            let dots = DotWave.dots(trace: steps(until: now), now: now, width: Self.width, height: Self.height)
            for (a, b) in zip(dots, dots.dropFirst()) { #expect(abs(a.radius - b.radius) < swell / 2) }
            if let previous {
                for (a, b) in zip(previous, dots) { #expect(abs(a.radius - b.radius) <= swell / 10 + 1e-9) }
            }
            previous = dots
        }
    }

    /// The row comes to rest in the aurora dot at the right: on the middle line past the row, inside the box,
    /// swelling a little with the voice.
    @Test func theRowSettlesIntoTheAuroraDot() throws {
        for level in [0, 0.6, 1.0] {
            let mark = DotWave.markDot(level: level, width: Self.width, height: Self.height)
            #expect(abs(mark.y - Self.height / 2) < 1e-9)
            #expect(mark.x + mark.radius <= Self.width + 1e-9 && mark.x - mark.radius >= 0)
            let last = try #require(Self.held(level).max { $0.x < $1.x })
            #expect(mark.x - mark.radius > last.x + last.radius + 1)
        }
        #expect(DotWave.markDot(level: 1, width: Self.width, height: Self.height).radius
            > DotWave.markDot(level: 0, width: Self.width, height: Self.height).radius)
    }

    /// Every dot and the aurora dot lie wholly inside the box, for any level; a box with no room draws nothing, and
    /// odd clocks and levels never break the trace.
    @Test func theWaveStaysInsideItsBox() {
        let loud = Self.trace(until: 1) { _ in 1 }
        for (w, h) in [(180.0, 24.0), (90, 20), (56, 24), (40, 12)] {
            for level in [0, 0.4, 1, 7, -1, .nan, .infinity] {
                let dots = Self.held(level, width: w, height: h) + DotWave.dots(trace: loud, now: 1, width: w, height: h)
                    + [DotWave.markDot(level: level, width: w, height: h)]
                for dot in dots {
                    #expect(dot.x - dot.radius >= -1e-9 && dot.x + dot.radius <= w + 1e-9
                        && dot.y - dot.radius >= -1e-9 && dot.y + dot.radius <= h + 1e-9)
                    #expect(dot.radius > 0 && dot.brightness >= 0 && dot.brightness <= 1)
                }
            }
        }
        #expect(Self.held(1, width: 4, height: 24).isEmpty)
        #expect(Self.held(1, width: 100, height: 2).isEmpty)
        var odd = DotWave.Trace()
        for (level, time) in [(0.5, 0.0), (.nan, 0.1), (2, 0.05), (0.5, .nan), (1, 0.2)] { odd.record(level, at: time) }
        for now in [0.2, -1, .nan, 1e9] {
            let lift = DotWave.lift(at: 0.9, trace: odd, now: now)
            #expect(lift.isFinite && lift >= 0 && lift <= 1)
        }
    }

    /// The wait's shimmer is the wave's row with a brighter, larger spot that moves left to right as the sweep runs,
    /// entering before the row and leaving after it once every 1.1 s; before it enters the row rests evenly.
    @Test func shimmerSweepsAlongTheRow() throws {
        let w = 120.0, h = 24.0
        var previous = -Double.infinity
        for sweep in [0.3, 0.5, 0.7] {
            let dots = DotWave.shimmer(sweep: sweep, width: w, height: h)
            #expect(dots.count >= 10)
            #expect(dots.allSatisfy { abs($0.y - h / 2) < 1e-9 })
            let brightest = try #require(dots.max { $0.brightness < $1.brightness })
            #expect(brightest.x > previous)
            #expect(brightest.radius == dots.map(\.radius).max())
            previous = brightest.x
            #expect(dots.allSatisfy { $0.x - $0.radius >= -1e-9 && $0.x + $0.radius <= w + 1e-9 })
        }
        #expect(Set(DotWave.shimmer(sweep: -1, width: w, height: h).map(\.brightness)).count == 1)
        #expect(DotWave.shimmer(sweep: 0.5, width: 2, height: h).isEmpty)
        #expect(DotWave.sweep(at: 0) < 0)
        #expect(DotWave.sweep(at: DotWave.shimmerPeriod * 0.999) > 1)
        #expect(abs(DotWave.sweep(at: 3.3 + 0.4) - DotWave.sweep(at: 0.4)) < 1e-9)
        #expect(DotWave.sweep(at: .nan) == -1)
    }

    /// The recorder is the pill's frame loop: the same moment drawn twice changes nothing, a long stall is caught up
    /// as a tenth of a second, and a new capture starts the row from rest.
    @Test func theRecorderStartsEachCaptureFromRest() {
        var recorder = DotWave.Recorder()
        for frame in 0 ... 60 { recorder.record(1, capture: 1, at: Double(frame) / 60) }
        #expect(recorder.level > 0.99)
        let before = recorder
        recorder.record(0, capture: 1, at: 1)
        #expect(recorder == before)
        recorder.record(0, capture: 1, at: 50)
        #expect(recorder.level > 0.2, "a stall dropped the level at once")
        recorder.record(0, capture: 2, at: 51)
        #expect(recorder.level == 0)
        #expect(recorder.trace.level(age: 0.5, now: 51) == 0)
        recorder.record(1, capture: 2, at: .nan)
        #expect(recorder.level == 0)
    }
}

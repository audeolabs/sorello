import Foundation

/// The listening wave (ARCHITECTURE.md, section 8, "Listening"): one row of dots along the pill's middle line that
/// shows the voice, its dots growing and brightening with what was said, and comes to rest in the mark's aurora dot
/// beside the housing. In silence it is one calm row of equal dots. The row's shape is the voice's own, the last
/// `span` seconds of it, the newest beside the aurora dot; what was said moves away from it as it ages, so a syllable
/// is a pulse that crosses the row in 0.75 s. The pill records the level (`LevelFollower`) into a `Trace` every frame;
/// which dot is how large and bright for a trace and a moment is all decided here, so the view only draws.
public enum DotWave {
    /// One dot, in its box's points: its centre, radius, and brightness from 0 (unlit) to 1.
    public struct Dot: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var brightness: Double

        public init(x: Double, y: Double, radius: Double, brightness: Double) {
            self.x = x
            self.y = y
            self.radius = radius
            self.brightness = brightness
        }
    }

    /// The distance between neighbouring dots, in points.
    public static let pitch = 6.2
    /// A dot at rest: its radius and brightness (a calm line, not a texture).
    public static let restRadius = 1.4
    public static let restBrightness = 0.5
    /// A dot at the top of the swell, still clear of its neighbours.
    public static let fullRadius = 2.85
    /// The aurora dot: its radius at rest, and how much the voice swells it.
    public static let markRadius = 2.55
    public static let markGrowth = 0.35
    /// How many seconds of the voice the row shows: a syllable crosses it in this long, a little quicker than the
    /// wait's 1.1 s sweep, so the wider listening pill does not read slower than the wait.
    public static let span = 0.75
    /// One sweep of the wait's shimmer, in seconds, entering at one end and leaving at the other.
    public static let shimmerPeriod = 1.1
    /// The row reads the voice this long ago at its newest end, so the trace's softening has samples on both sides
    /// there and the dot beside the aurora dot never jumps as a new level arrives (the aurora dot swells with the
    /// voice now).
    public static let readDelay = 0.045
    /// The wave's and the shimmer's frame interval: at most 60 frames a second, even on a 120 Hz display.
    public static let frameInterval = 1.0 / 60

    /// The widest any dot of the wave gets, the aurora dot included: what a box must leave for it at each end.
    public static var widestRadius: Double { max(fullRadius, markRadius * (1 + markGrowth)) }

    /// How much of the swell a level (0 to 1, clamped; not a number is silence) takes: nothing for the quietest
    /// levels, a background murmur, then rising faster than the level, so a loud word looks clearly larger than a
    /// quiet one.
    public static func voice(_ level: Double) -> Double {
        guard !level.isNaN else { return 0 }
        let level = min(max(level, 0), 1)
        return pow(max(level - 0.15, 0) / 0.85, 1.5)
    }

    /// The row's dots' x positions in a box, leaving `trailing` points at the right; centred, a pitch apart, with room
    /// for the largest dot at each end. Empty without room for three dots or for the largest dot's height.
    public static func row(width: Double, height: Double, trailing: Double = 0) -> [Double] {
        let margin = fullRadius
        let span = width - trailing - 2 * margin
        guard height >= 2 * fullRadius, span.isFinite, span >= 2 * pitch else { return [] }
        let columns = Int((span / pitch).rounded(.down))
        let minX = margin + (span - Double(columns) * pitch) / 2
        return (0 ... columns).map { minX + Double($0) * pitch }
    }

    /// The room the aurora dot takes at the row's right: its widest, and a gap.
    static let markRoom = 2 * markRadius * (1 + markGrowth) + pitch * 0.9

    /// How far the row lets the voice lift the dot `u` of the way along it (0 at the far end, 1 beside the aurora
    /// dot): none at the far end, so the voice rises out of the line there, all of it from a little past the middle,
    /// a little less beside the aurora dot, which it settles into.
    private static func envelope(_ u: Double) -> Double {
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        return smooth(0, 0.6, u) * (1 - 0.2 * smooth(0.85, 1, u))
    }

    /// How far the voice lifts the dot `u` of the way along the row, 0 at rest and 1 at the top of the swell, where
    /// `levelAt(age)` is the level heard `age` seconds ago: the dot at `u` shows what was said `(1 - u) * span` ago.
    public static func lift(at u: Double, levelAt: (Double) -> Double) -> Double {
        let u = u.isFinite ? min(max(u, 0), 1) : 0
        let lift = voice(levelAt((1 - u) * span)) * envelope(u)
        return lift.isFinite ? min(max(lift, 0), 1) : 0
    }

    /// The lift for the voice in `trace` at the moment `now`.
    public static func lift(at u: Double, trace: Trace, now: Double) -> Double {
        lift(at: u) { trace.level(age: $0 + readDelay, now: now) }
    }

    /// The wave's dots in a `width` by `height` box for the voice `levelAt(age)` (as `lift`). No room, no dots.
    public static func dots(width: Double, height: Double, levelAt: (Double) -> Double) -> [Dot] {
        let xs = row(width: width, height: height, trailing: markRoom)
        guard let first = xs.first, let last = xs.last, last > first else { return [] }
        let length = last - first
        return xs.map { x in
            let lift = lift(at: (x - first) / length, levelAt: levelAt)
            return Dot(x: x, y: height / 2, radius: restRadius + (fullRadius - restRadius) * lift,
                       brightness: restBrightness + (1 - restBrightness) * lift)
        }
    }

    /// The wave's dots for the voice in `trace` at the moment `now`.
    public static func dots(trace: Trace, now: Double, width: Double, height: Double) -> [Dot] {
        dots(width: width, height: height) { trace.level(age: $0 + readDelay, now: now) }
    }

    /// The wave's dots for a voice held at `level` for the whole row: with Reduce Motion the row stands still at each
    /// level.
    public static func dots(level: Double, width: Double, height: Double) -> [Dot] {
        dots(width: width, height: height) { _ in level }
    }

    /// How bright the shimmer's spot makes the dot `u` of the way along a row whose spot is at `sweep` (as `shimmer`):
    /// 0 away from it, 1 under it.
    public static func glow(at u: Double, sweep: Double, spread: Double = 0.22) -> Double {
        let d = ((u.isFinite ? u : 0) - (sweep.isFinite ? sweep : -1)) / max(spread, 0.01)
        let glow = exp(-d * d)
        return glow < 0.01 ? 0 : glow
    }

    /// The aurora dot the row settles into: on the middle line at the box's right, swelling a little with the voice.
    public static func markDot(level: Double, width: Double, height: Double) -> Dot {
        let widest = markRadius * (1 + markGrowth)
        let radius = min(markRadius * (1 + markGrowth * voice(level)), max(height / 2, 0.01))
        return Dot(x: max(width - widest, radius), y: height / 2, radius: radius, brightness: 1)
    }

    /// The wait's shimmer, the wave's row at rest with a brighter, larger spot centred `sweep` of the way along it (0
    /// at the left end, 1 at the right; outside that it is entering or leaving).
    public static func shimmer(sweep: Double, width: Double, height: Double) -> [Dot] {
        shimmer(sweep: sweep, row: row(width: width, height: height), height: height)
    }

    /// The shimmer over a row of dots at `xs` (as `row` lays them out): the pill uses this for a row that the housing
    /// interrupts, whose dots under the housing are left out after the spot has been placed along the whole row.
    public static func shimmer(sweep: Double, row xs: [Double], height: Double) -> [Dot] {
        guard let first = xs.first, let last = xs.last, last > first else { return [] }
        let length = last - first
        let spread = max(0.22, pitch / length)
        return xs.map { x in
            let lift = glow(at: (x - first) / length, sweep: sweep, spread: spread)
            return Dot(x: x, y: height / 2, radius: restRadius + (fullRadius - restRadius) * 0.7 * lift,
                       brightness: 0.45 + 0.55 * lift)
        }
    }

    /// Where the shimmer's spot is at `time`: it enters before the row's start and leaves after its end, once every
    /// `shimmerPeriod`.
    public static func sweep(at time: Double) -> Double {
        guard time.isFinite else { return -1 }
        let phase = time.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
        return (phase < 0 ? phase + 1 : phase) * 1.6 - 0.3
    }

    /// The level the wave draws: the input's, smoothed so it rises with a syllable at once and falls quickly after it
    /// (so syllables read as distinct pulses), without stepping between the levels the meter gives (ten a second).
    public struct LevelFollower: Equatable, Sendable {
        /// The time constants of the rise and the fall, in seconds.
        public static let rise = 0.025
        public static let fall = 0.09

        public private(set) var value = 0.0

        public init() {}

        /// Moves towards `target` (clamped to 0...1; not a number is silence) over `seconds` of the display's clock.
        public mutating func follow(_ target: Double, over seconds: Double) {
            guard seconds > 0 else { return }
            let target = target.isNaN ? 0 : min(max(target, 0), 1)
            let constant = target > value ? Self.rise : Self.fall
            value += (target - value) * (1 - exp(-seconds / constant))
        }
    }

    /// The voice over the last `span` seconds, as the pill records it each frame: what the row shows. A level read
    /// back is softened over `blur` seconds either side, so levels that arrive ten times a second draw a smooth row,
    /// and a dot changes gently from frame to frame as the row moves.
    public struct Trace: Equatable, Sendable {
        /// The softening's standard deviation, in seconds.
        public static let blur = 0.06

        private var times: [Double] = []
        private var levels: [Double] = []

        public init() {}

        /// Adds the level heard at `time` (clamped to 0...1; not a number is silence). A time that is not after the
        /// last is ignored; samples older than the row shows are dropped.
        public mutating func record(_ level: Double, at time: Double) {
            guard time.isFinite, times.last.map({ time > $0 }) ?? true else { return }
            times.append(time)
            levels.append(level.isNaN ? 0 : min(max(level, 0), 1))
            let oldest = time - DotWave.span - 4 * Self.blur
            if let keep = times.firstIndex(where: { $0 >= oldest }), keep > 0 {
                times.removeFirst(keep)
                levels.removeFirst(keep)
            }
        }

        /// The level heard `age` seconds before `now`, softened; 0 where nothing was recorded.
        public func level(age: Double, now: Double) -> Double {
            let at = now - age
            guard at.isFinite, !times.isEmpty else { return 0 }
            let reach = 2.5 * Self.blur
            // The first sample in reach, by bisection: the trace is in time order.
            var index = 0, high = times.count
            while index < high {
                let middle = (index + high) / 2
                if times[middle] < at - reach { index = middle + 1 } else { high = middle }
            }
            var sum = 0.0, weights = 0.0
            while index < times.count, times[index] <= at + reach {
                let d = (times[index] - at) / Self.blur
                let weight = exp(-0.5 * d * d)
                sum += weight * levels[index]
                weights += weight
                index += 1
            }
            return weights > 0 ? sum / weights : 0
        }
    }

    /// The follower and the trace together, as the pill drives them: once a frame it hands over the latest level and
    /// the frame's time, and reads back the trace the row shows. A new capture starts both from rest, so one
    /// dictation's voice never runs into the next's row.
    public struct Recorder: Equatable, Sendable {
        /// The longest step the follower takes in one frame: after a stall it catches up as if a tenth of a second
        /// had passed, not all of it at once.
        public static let longestStep = 0.1

        public private(set) var trace = Trace()
        public private(set) var follower = LevelFollower()
        private var lastFrame: Double?
        private var capture: UInt64?

        public init() {}

        /// The level the row shows now: the followed level.
        public var level: Double { follower.value }

        /// Records `level`, heard during `capture`, for the frame at `now`. Only a frame after the last one moves the
        /// row, so drawing the same moment twice changes nothing.
        public mutating func record(_ level: Double, capture: UInt64?, at now: Double) {
            if capture != self.capture {
                self = Recorder()
                self.capture = capture
            }
            guard now.isFinite, now > (lastFrame ?? -.infinity) else { return }
            follower.follow(level, over: min(now - (lastFrame ?? now), Self.longestStep))
            trace.record(follower.value, at: now)
            lastFrame = now
        }
    }
}

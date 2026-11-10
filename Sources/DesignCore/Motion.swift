import CoreGraphics
import Foundation

/// A damped spring as SwiftUI's `spring(response:dampingFraction:)` moves a value: unit mass, stiffness
/// (2π/response)², damping 4π·dampingFraction/response. The pill's body is moved with one, frame by frame, so its
/// shape at a moment is a pure function of where it set off and when.
public struct Spring: Equatable, Sendable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }
}

/// Every timing of the pill (ARCHITECTURE.md, section 8, "Motion"), in one place.
public enum Motion {
    /// The body growing and shrinking between forms: quick and firm, a touch of give, no wobble.
    public static let body = Spring(response: 0.26, dampingFraction: 0.88)
    /// The cancel button budding off the pill and being taken back: a touch behind the body and with a little more
    /// give, so it swells out of the pill's end and pinches free.
    public static let bud = Spring(response: 0.34, dampingFraction: 0.74)
    /// At each change of form what leaves fades first, in this long, and what arrives follows after it.
    public static let handover = 0.06
    /// How long what arrives takes to fade in, once what left has gone.
    public static let arrival = 0.12
    /// With Reduce Motion nothing travels: each form cross-fades into the next in this long.
    public static let crossFade = 0.15
    /// The body fading in as it drops down from the band, and out as it goes back up.
    public static let appear = 0.15

    /// The body's fade: after what delay and for how long. Leaving, the content goes first; with Reduce Motion
    /// everything cross-fades together.
    public static func bodyFade(showing: Bool, reduceMotion: Bool) -> (delay: Double, duration: Double) {
        reduceMotion ? (0, crossFade) : (showing ? 0 : handover, appear)
    }

    /// How long after the pill is hidden its last fade ends, content and body: it is not at rest before then.
    public static func hideFades(reduceMotion: Bool) -> Double {
        let content = reduceMotion ? crossFade : handover
        let body = bodyFade(showing: false, reduceMotion: reduceMotion)
        return max(content, body.delay + body.duration)
    }
}

/// A value moving under a spring from where it was, at the speed it had, towards a target. Its value at a moment is
/// computed in closed form, so a frame drawn twice for the same moment is the same frame, and a target changed midway
/// carries the motion on from where it is and as fast.
public struct SpringValue: Equatable, Sendable {
    public private(set) var target: Double
    private var origin: Double
    private var speed = 0.0
    private var start = 0.0
    private var spring = Motion.body

    public init(_ value: Double) {
        target = value.isFinite ? value : 0
        origin = target
    }

    public func value(at time: TimeInterval) -> Double { state(at: time).value }
    public func velocity(at time: TimeInterval) -> Double { state(at: time).velocity }

    /// Close enough to its target, slowly enough, to stop drawing: within a hundredth of a point and moving under half
    /// a point a second.
    public func isSettled(at time: TimeInterval) -> Bool {
        let now = state(at: time)
        return abs(now.value - target) < 0.01 && abs(now.velocity) < 0.5
    }

    /// From where it is at `now` and as fast, towards `target`, after `delay` held still. A target that is not a
    /// number changes nothing.
    public mutating func move(to target: Double, with spring: Spring, at now: TimeInterval, delay: Double = 0) {
        guard target.isFinite, now.isFinite else { return }
        let current = state(at: now)
        origin = current.value
        speed = delay > 0 ? 0 : current.velocity
        start = now + max(delay, 0)
        self.target = target
        self.spring = spring
    }

    /// At `value` at once, at rest.
    public mutating func snap(to value: Double) {
        guard value.isFinite else { return }
        target = value
        origin = value
        speed = 0
    }

    private func state(at time: TimeInterval) -> (value: Double, velocity: Double) {
        let t = time - start
        guard t > 0, t.isFinite, spring.response > 0 else {
            // Long past (or no spring at all): there.
            if t > 0 { return (target, 0) }
            return (origin, t == 0 ? speed : 0)
        }
        let natural = 2 * Double.pi / spring.response, zeta = max(spring.dampingFraction, 0)
        let offset = origin - target
        if zeta < 1 {
            let damped = natural * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * natural * t)
            let a = offset, b = (speed + zeta * natural * offset) / damped
            let c = cos(damped * t), s = sin(damped * t)
            let value = decay * (a * c + b * s)
            let velocity = decay * (-zeta * natural * (a * c + b * s) + damped * (-a * s + b * c))
            return (target + value, velocity)
        }
        let b = speed + natural * offset
        let decay = exp(-natural * t)
        return (target + (offset + b * t) * decay, (b - natural * (offset + b * t)) * decay)
    }
}

/// The pill's body moving between forms: each edge and each radius on the body's spring, so one shape morphs into
/// the next (the rest into the capsule, a capsule into a card) and the outline at a moment is a pure function.
public struct MovingBody: Equatable, Sendable {
    private var minX, minY, maxX, maxY, top, bottom: SpringValue

    public init(_ body: PillBody) {
        minX = SpringValue(Double(body.frame.minX))
        minY = SpringValue(Double(body.frame.minY))
        maxX = SpringValue(Double(body.frame.maxX))
        maxY = SpringValue(Double(body.frame.maxY))
        top = SpringValue(body.topRadius)
        bottom = SpringValue(body.bottomRadius)
    }

    /// Where it is going.
    public var target: PillBody {
        PillBody(frame: CGRect(x: minX.target, y: minY.target, width: maxX.target - minX.target,
                               height: maxY.target - minY.target),
                 topRadius: top.target, bottomRadius: bottom.target)
    }

    /// From where it is at `now`, and as fast, towards `body`.
    public mutating func move(to body: PillBody, at now: TimeInterval, with spring: Spring = Motion.body) {
        minX.move(to: Double(body.frame.minX), with: spring, at: now)
        minY.move(to: Double(body.frame.minY), with: spring, at: now)
        maxX.move(to: Double(body.frame.maxX), with: spring, at: now)
        maxY.move(to: Double(body.frame.maxY), with: spring, at: now)
        top.move(to: body.topRadius, with: spring, at: now)
        bottom.move(to: body.bottomRadius, with: spring, at: now)
    }

    /// At `body` at once.
    public mutating func snap(to body: PillBody) {
        self = MovingBody(body)
    }

    /// The outline at `now`. Its width and height never go below zero, even while the spring overshoots.
    public func body(at now: TimeInterval) -> PillBody {
        let x0 = minX.value(at: now), y0 = minY.value(at: now)
        let x1 = max(maxX.value(at: now), x0), y1 = max(maxY.value(at: now), y0)
        return PillBody(frame: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                        topRadius: max(top.value(at: now), 0), bottomRadius: max(bottom.value(at: now), 0))
    }

    public func isSettled(at now: TimeInterval) -> Bool {
        [minX, minY, maxX, maxY, top, bottom].allSatisfy { $0.isSettled(at: now) }
    }
}

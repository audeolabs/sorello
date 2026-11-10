import Foundation

/// The cancel button as a bud of the pill (ARCHITECTURE.md, section 8, "Listening"): in toggle mode it swells out of
/// the pill's trailing end, joined by a neck that thins to nothing as the gap opens, so it pinches free; its × fades in
/// as it parts. When toggle listening ends the pill takes it back. The pill, the bud and the neck are drawn as one
/// body, so the × looks like part of the pill. This is its motion and shape along the pill's middle line, in screen
/// points; what takes the click is the bud's resting circle (`PillLayout.cancel`).
public enum CancelBud {
    /// The bud at home, hidden in the pill's end: `homeRadius` round, its centre `homeInset` in from the end's.
    public static let homeRadius = 7.0
    public static let homeInset = 3.0
    /// The neck thins to nothing as the gap between the pill and the bud opens to this, under the resting gap
    /// (`PillGeometry.budGap`), so a bud resting beside the pill is never joined to it.
    public static let reach = 9.0
    /// How far the neck spreads over the two circles while they overlap (0 is a point, 1 their outer tangents).
    public static let spread = 0.6

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The neck's outline, closed: from `p1` on the pill's end along the top curve (handles `h1`, `h3`) to `p3` on the
    /// bud's edge, across to `p4`, and back along the bottom curve (handles `h4`, `h2`) to `p2`. Its straight sides
    /// lie inside the two circles, which are drawn with it.
    public struct Neck: Equatable, Sendable {
        public var p1, h1, h3, p3, p4, h4, h2, p2: Point
    }

    /// The neck between the pill's end, a circle `radius` r1 about `body` (c1), and the bud, a circle r2 about `bud`
    /// (c2), on the middle line `y`: a metaball bridge whose spread narrows to nothing as the gap between them opens to
    /// `reach`; none once it has, or while the bud lies wholly inside the pill's end.
    public static func neck(body c1: Double, radius r1: Double, bud c2: Double, radius r2: Double, y: Double) -> Neck? {
        let d = abs(c2 - c1)
        guard r1 > 0, r2 > 0, d.isFinite, d > abs(r1 - r2) + 0.01, d < r1 + r2 + reach else { return nil }
        var u1 = 0.0, u2 = 0.0
        if d < r1 + r2 {
            u1 = acos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d))
            u2 = acos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d))
        }
        let gap = d - r1 - r2
        let v = spread * (gap > 0 ? pow(1 - gap / reach, 1.6) : 1)
        let towards = c2 > c1 ? 0 : Double.pi
        let widest = acos(max(-1, min(1, (r1 - r2) / d)))
        let a1 = towards + u1 + (widest - u1) * v, a2 = towards - u1 - (widest - u1) * v
        let a3 = towards + .pi - u2 - (.pi - u2 - widest) * v, a4 = towards - .pi + u2 + (.pi - u2 - widest) * v
        func on(_ centre: Double, _ angle: Double, _ radius: Double) -> Point {
            Point(x: centre + radius * cos(angle), y: y + radius * sin(angle))
        }
        let p1 = on(c1, a1, r1), p2 = on(c1, a2, r1), p3 = on(c2, a3, r2), p4 = on(c2, a4, r2)
        let handle = min(v * 2.4, hypot(p1.x - p3.x, p1.y - p3.y) / (r1 + r2)) * min(1, d * 2 / (r1 + r2))
        // A handle never reaches past the middle line, so the neck's two sides never cross as it thins.
        func from(_ point: Point, _ angle: Double, _ length: Double) -> Point {
            var length = length
            if sin(angle) != 0, (y - point.y) / sin(angle) >= 0 { length = min(length, (y - point.y) / sin(angle)) }
            return Point(x: point.x + length * cos(angle), y: point.y + length * sin(angle))
        }
        return Neck(p1: p1, h1: from(p1, a1 - .pi / 2, r1 * handle), h3: from(p3, a3 + .pi / 2, r2 * handle), p3: p3,
                    p4: p4, h4: from(p4, a4 - .pi / 2, r2 * handle), h2: from(p2, a2 + .pi / 2, r1 * handle), p2: p2)
    }

    /// What to draw at a moment: the bud's circle (none while it is home), the neck joining it to the pill, and how
    /// opaque its × is.
    public struct Frame: Equatable, Sendable {
        /// The bud's centre on the middle line and its radius.
        public var centre: Double
        public var radius: Double
        public var neck: Neck?
        public var glyphAlpha: Double
    }

    /// The bud over time. The pill tells it where the pill's end is and whether the bud should be out (`update`), and
    /// draws `frame(at:)` while `needsFrames`.
    public struct Model: Equatable, Sendable {
        private var centre = SpringValue(0)
        private var radius = SpringValue(homeRadius)
        private var phase = Phase.home

        private enum Phase: Equatable {
            /// In the pill: nothing to draw.
            case home
            /// Out of the pill, at rest beside it or on its way there.
            case out
            /// On its way back into the pill since then.
            case absorbing(since: TimeInterval)
        }

        public init() {}

        /// Whether the bud is out, or on its way out or back.
        public var isShowing: Bool { phase != .home }

        /// Moves the bud from `now`: out to `resting` (its circle, as `PillLayout.cancel` gives it) or, with nil, back
        /// into the pill's end at `end` with the pill's middle-line `radius`. `animated` false places it at once (Reduce
        /// Motion, or a pill that is appearing or changing screens).
        public mutating func update(resting: (centre: Double, radius: Double)?, end: Double, endRadius: Double,
                                    animated: Bool, now: TimeInterval) {
            let home = end - endRadius + CancelBud.homeInset
            if let resting {
                if !animated {
                    centre.snap(to: resting.centre)
                    radius.snap(to: resting.radius)
                } else if phase == .out {
                    // Beside the pill as it changes size: in the body's spring, keeping its gap.
                    centre.move(to: resting.centre, with: Motion.body, at: now)
                    radius.move(to: resting.radius, with: Motion.body, at: now)
                } else {
                    if phase == .home {
                        centre.snap(to: home)
                        radius.snap(to: CancelBud.homeRadius)
                    }
                    centre.move(to: resting.centre, with: Motion.bud, at: now)
                    radius.move(to: resting.radius, with: Motion.bud, at: now)
                }
                phase = .out
                return
            }
            guard phase != .home else { return }
            guard animated else {
                phase = .home
                return
            }
            if phase == .out { phase = .absorbing(since: now) }
            centre.move(to: home, with: Motion.bud, at: now)
            radius.move(to: CancelBud.homeRadius, with: Motion.bud, at: now)
        }

        /// Moves the phase on at `now`: a bud taken back is gone once it is inside.
        public mutating func advance(to now: TimeInterval) {
            if case .absorbing = phase, centre.isSettled(at: now), radius.isSettled(at: now) { phase = .home }
        }

        /// Whether the bud moves at `now`: the pill draws frames only then.
        public func needsFrames(at now: TimeInterval) -> Bool {
            switch phase {
            case .home: false
            case .absorbing: true
            case .out: !centre.isSettled(at: now) || !radius.isSettled(at: now)
            }
        }

        /// The bud at `now` beside a pill whose end circle is centred at `end - endRadius` on the line `y`.
        public func frame(at now: TimeInterval, end: Double, endRadius: Double, y: Double) -> Frame? {
            guard phase != .home else { return nil }
            let c = centre.value(at: now), r = max(radius.value(at: now), 0.01)
            let c1 = end - endRadius
            let neck = CancelBud.neck(body: c1, radius: endRadius, bud: c, radius: r, y: y)
            let gap = abs(c - c1) - endRadius - r
            let parting = min(max((gap + 2) / 10, 0), 1)
            var glyph = parting
            if case .absorbing(let since) = phase {
                glyph = min(parting, max(1 - (now - since) / Motion.handover, 0))
            }
            return Frame(centre: c, radius: r, neck: neck, glyphAlpha: glyph)
        }
    }
}

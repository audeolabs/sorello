import CoreGraphics
import DesignCore
import Foundation
import Testing

/// ARCHITECTURE.md, section 8, "Motion": the body moves on a spring (response 0.26 s, damping 0.88), what leaves fades
/// in 0.06 s before what arrives, and Reduce Motion cross-fades in 0.15 s. The cancel bud is ported from the iPhone's.
@Suite struct MotionTests {
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func theTimingsAreTheContracts() {
        #expect(Motion.body == Spring(response: 0.26, dampingFraction: 0.88))
        #expect(Motion.handover == 0.06)
        #expect(Motion.crossFade == 0.15)
    }

    /// Leaving, the content fades first and the body after it; with Reduce Motion everything cross-fades at once in
    /// 0.15 s.
    @Test func theBodyFadesAfterTheContentLeaves() {
        let leaving = Motion.bodyFade(showing: false, reduceMotion: false)
        #expect(leaving.delay == Motion.handover && leaving.duration == Motion.appear)
        #expect(Motion.bodyFade(showing: true, reduceMotion: false).delay == 0)
        for showing in [false, true] {
            let still = Motion.bodyFade(showing: showing, reduceMotion: true)
            #expect(still.delay == 0 && still.duration == Motion.crossFade)
        }
    }

    /// A fade is a straight line from where it is to its target, after its delay, and its value at a moment depends
    /// only on the moment. Turned round midway it carries on from where it is; turned round before it began, it never
    /// moved.
    @Test func fadesAreAPureFunctionOfTheMoment() {
        var fade = Fade(0)
        #expect(fade.value(at: 5) == 0 && fade.isSettled(at: 5))
        fade.move(to: 1, at: 10, delay: 0.1, duration: 0.2)
        #expect(fade.target == 1)
        #expect(fade.value(at: 10.05) == 0 && !fade.isSettled(at: 10.05))
        #expect(MotionTests.near(fade.value(at: 10.2), 0.5))
        #expect(fade.value(at: 10.3) == 1 && fade.isSettled(at: 10.3) && fade.value(at: 99) == 1)
        fade.move(to: 0, at: 10.25, duration: 0.3)
        #expect(MotionTests.near(fade.value(at: 10.25), 0.75))
        #expect(MotionTests.near(fade.value(at: 10.4), 0.375))
        #expect(fade.value(at: 10.6) == 0 && fade.isSettled(at: 10.6))
        var early = Fade(1)
        early.move(to: 0, at: 0, delay: 0.06, duration: 0.15)
        early.move(to: 1, at: 0.03, duration: 0.15)
        #expect(early.value(at: 0.03) == 1 && early.value(at: 0.1) == 1, "a fade-out that had not begun dimmed it")
        var odd = Fade(.nan)
        #expect(odd.value(at: 0) == 0)
        odd.move(to: 7, at: 0, duration: -1)
        #expect(odd.value(at: 0) == 1, "a fade beyond fully opaque, or with no duration")
        odd.snap(to: 0.4)
        #expect(odd.value(at: -3) == 0.4 && odd.isSettled(at: -3))
    }

    /// The body drops from the rest, touching the foot of the band, to its place, growing only outward from it, and
    /// goes back up the same way. On no frame does any of it reach into the band: not as the spring overshoots on the
    /// way back up, nor when it is sent back midway or called back while it goes.
    @Test(arguments: PillGeometryTests.screens)
    func theBodyNeverEntersTheBand(screen: ScreenTopology) {
        let rest = PillGeometry.layout(.rest, on: screen).body
        let foot = Double(rest.frame.minY)
        let forms: [PillForm] = [.listening(trailing: 30, cancel: false), .listening(trailing: 52, cancel: true),
                                 .waiting(trailing: nil), .notice(CGSize(width: 300, height: 90))]
        for form in forms {
            let target = PillGeometry.layout(form, on: screen).body
            var drop = MovingBody(rest, ceiling: foot)
            drop.move(to: target, at: 0)
            #expect(drop.body(at: 0) == rest)
            var outward = true
            for step in 0 ... 600 {
                let frame = drop.body(at: Double(step) / 600).frame
                outward = outward && frame.minX <= rest.frame.minX + 1e-9 && frame.maxX >= rest.frame.maxX - 1e-9
                    && frame.minY >= rest.frame.minY - 1e-9 && frame.maxY >= rest.frame.maxY - 1e-9
            }
            #expect(outward, "\(form) does not grow out of the rest on \(screen)")
            let settled = drop.body(at: 1).frame
            #expect(drop.isSettled(at: 1) && abs(settled.minX - target.frame.minX) < 0.01
                && abs(settled.maxY - target.frame.maxY) < 0.01)
            for hide in [0.03, 0.1, 0.25, 2.0] {
                for back in [nil, 0.02, 0.08, 0.2] as [Double?] {
                    var body = MovingBody(rest, ceiling: foot)
                    body.move(to: target, at: 0)
                    body.move(to: rest, at: hide)
                    if let back { body.move(to: target, at: hide + back) }
                    let highest = (0 ... 4000).map { Double(body.body(at: Double($0) / 1000).frame.minY) }.min() ?? 0
                    #expect(highest >= foot - 1e-9, "\(form) reached \(foot - highest) pt into the band")
                }
            }
        }
    }

    /// A value moves as SwiftUI's `spring(response:dampingFraction:)` would: from rest, settling in about four
    /// responses with the overshoot of a damped harmonic spring. A new target keeps its place and speed; a delay
    /// holds it still.
    @Test func springsMoveAsSwiftUIsDo() throws {
        for spring in [Motion.body, Motion.bud] {
            var value = SpringValue(0)
            value.move(to: 100, with: spring, at: 1)
            #expect(Self.near(value.value(at: 1), 0) && Self.near(value.velocity(at: 1), 0))
            #expect(Self.near(value.value(at: 1 + 4 * spring.response), 100, 0.05))
            let zeta = spring.dampingFraction
            let overshoot = 100 * exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot())
            let peak = try #require(stride(from: 1.0, through: 3, by: 0.0005).map { value.value(at: $0) }.max())
            #expect(Self.near(peak - 100, overshoot, 0.05))
            let before = (value.value(at: 1.08), value.velocity(at: 1.08))
            value.move(to: 40, with: spring, at: 1.08)
            #expect(Self.near(value.value(at: 1.08), before.0, 1e-9) && Self.near(value.velocity(at: 1.08), before.1))
            #expect(Self.near(value.value(at: 3), 40, 0.05))
            #expect(value.isSettled(at: 3) && !value.isSettled(at: 1.1))
            var held = SpringValue(10)
            held.move(to: 20, with: spring, at: 0, delay: 0.02)
            #expect(Self.near(held.value(at: 0.019), 10, 1e-9))
            #expect(held.value(at: 0.05) > 10)
        }
        var odd = SpringValue(5)
        odd.move(to: .nan, with: Motion.body, at: 0)
        odd.move(to: 9, with: Motion.body, at: .infinity)
        #expect(odd.value(at: 1) == 5 && odd.target == 5)
        #expect(odd.value(at: .infinity) == 5)
        odd.move(to: 9, with: Motion.body, at: 0)
        #expect(odd.value(at: .infinity) == 9)
    }

    /// The body's grow is quick (most of the way in 0.2 s) and firm (it overshoots by under a point on a 200 pt
    /// change), and its outline at a moment depends only on the moment.
    @Test func theBodyMorphsQuicklyAndFirmly() {
        let from = PillBody(frame: CGRect(x: 790, y: 48, width: 156, height: 36), topRadius: 18, bottomRadius: 18)
        let to = PillBody(frame: CGRect(x: 690, y: 48, width: 356, height: 120), topRadius: 20, bottomRadius: 20)
        var body = MovingBody(from)
        body.move(to: to, at: 10)
        #expect(body.body(at: 10) == from)
        #expect(body.target == to)
        let at = body.body(at: 10.2)
        #expect(Double(at.frame.width) > 156 + 0.9 * 200)
        var widest = 0.0
        for step in 0 ... 200 {
            let frame = body.body(at: 10 + Double(step) / 200).frame
            widest = max(widest, Double(frame.width))
            #expect(frame.width >= 0 && frame.height >= 0)
        }
        #expect(widest - 356 < 1 && widest >= 356 - 0.01)
        #expect(body.isSettled(at: 11.5) && !body.isSettled(at: 10.1))
        #expect(body.body(at: 10.13) == body.body(at: 10.13))
        // Retargeted halfway, it carries on from where it is.
        let halfway = body.body(at: 10.1)
        body.move(to: from, at: 10.1)
        #expect(body.body(at: 10.1) == halfway)
        body.snap(to: to)
        #expect(body.body(at: 0) == to && body.isSettled(at: 0))
        // Sent on after a delay, it holds still where it is until then.
        var waiting = MovingBody(from)
        waiting.move(to: to, at: 0, delay: 0.06)
        #expect(waiting.body(at: 0.059) == from && waiting.body(at: 0.1) != from && waiting.target == to)
        // A ceiling holds the outline's top below it and keeps it through a snap.
        var held = MovingBody(to, ceiling: 60)
        #expect(held.body(at: 0).frame.minY == 60 && held.body(at: 0).frame.maxY == to.frame.maxY)
        held.snap(to: from)
        #expect(held.ceiling == 60 && held.body(at: 0).frame.minY == 60)
    }

    /// The radii as drawn never exceed half the width nor, together, the height, so any outline can be drawn.
    @Test func radiiAreAlwaysDrawable() {
        let body = PillBody(frame: CGRect(x: 0, y: 0, width: 20, height: 30), topRadius: 25, bottomRadius: 25)
        let radii = body.drawnRadii
        #expect(radii.top <= 10 && radii.bottom <= 10)
        let flat = PillBody(frame: CGRect(x: 0, y: 0, width: 200, height: 30), topRadius: 20, bottomRadius: 20)
        #expect(Self.near(flat.drawnRadii.top + flat.drawnRadii.bottom, 30))
        let negative = PillBody(frame: .zero, topRadius: -3, bottomRadius: 4)
        #expect(negative.drawnRadii.top == 0 && negative.drawnRadii.bottom == 0)
    }
}

/// The cancel bud (ported from the iPhone's island bud): it swells out of the pill's end, pinches free, rests a clear
/// gap away with no neck, and is taken back on the way out.
@Suite struct CancelBudTests {
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    /// A pill whose end circle is 16 pt round with its right end at x 1000, and the bud's resting circle beside it.
    static let end = 1000.0, endRadius = 16.0, y = 20.0
    static let resting = (centre: 1000 + PillGeometry.budGap + 12, radius: 12.0)

    /// The bud starts hidden inside the pill's end, joins it by a neck as it swells, pinches free within 0.3 s, and
    /// rests exactly at its place with its × fully in; once free it never rejoins and asks for no more frames.
    @Test func theBudStartsInsideThePillAndPinchesFree() throws {
        var model = CancelBud.Model()
        #expect(model.frame(at: 0, end: Self.end, endRadius: Self.endRadius, y: Self.y) == nil)
        model.update(resting: Self.resting, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: true, now: 0)
        let first = try #require(model.frame(at: 0, end: Self.end, endRadius: Self.endRadius, y: Self.y))
        #expect(first.centre + first.radius <= Self.end && first.radius < Self.endRadius)
        #expect(first.glyphAlpha == 0)
        var necks: [Double] = []
        var overshoot = 0.0
        for step in 0 ... 60 {
            let t = Double(step) / 60
            let frame = try #require(model.frame(at: t, end: Self.end, endRadius: Self.endRadius, y: Self.y))
            if frame.neck != nil { necks.append(t) }
            overshoot = max(overshoot, frame.centre + frame.radius - (Self.resting.centre + Self.resting.radius))
        }
        let joined = try #require(necks.first), free = try #require(necks.last)
        #expect(free <= 0.3)
        #expect(necks.count == Int(((free - joined) * 60).rounded()) + 1, "the neck rejoins")
        #expect(overshoot < PillGeometry.budGap)
        let last = try #require(model.frame(at: 1, end: Self.end, endRadius: Self.endRadius, y: Self.y))
        #expect(Self.near(last.centre, Self.resting.centre, 0.01) && Self.near(last.radius, Self.resting.radius, 0.01))
        #expect(last.glyphAlpha == 1 && last.neck == nil)
        #expect(!model.needsFrames(at: 1) && model.isShowing)
    }

    /// When the pill grows as the bud sets out (the wait turning into toggle listening), the bud swells from the end
    /// the pill has now, not the one it is growing to, so it never starts detached from the body.
    @Test func theBudSetsOutFromWhereThePillIsNow() throws {
        var model = CancelBud.Model()
        let now = 969.5, growing = 1005.5
        model.update(resting: (centre: growing + PillGeometry.budGap + 12, radius: 12), from: now, to: growing,
                     endRadius: Self.endRadius, animated: true, now: 0)
        let first = try #require(model.frame(at: 0, end: now, endRadius: Self.endRadius, y: Self.y))
        #expect(first.centre + first.radius <= now)
        #expect(first.glyphAlpha == 0)
    }

    /// A bud resting beside the pill is never joined to it: the neck lets go before the resting gap.
    @Test func aBudBesideThePillHasNoNeck() {
        #expect(CancelBud.reach < PillGeometry.budGap)
        var model = CancelBud.Model()
        model.update(resting: Self.resting, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: false, now: 0)
        #expect(model.frame(at: 0, end: Self.end, endRadius: Self.endRadius, y: Self.y)?.neck == nil)
        #expect(model.frame(at: 0, end: Self.end, endRadius: Self.endRadius, y: Self.y)?.glyphAlpha == 1)
        #expect(!model.needsFrames(at: 0))
    }

    /// The neck meets both circles, thins steadily as the gap opens and is under half a point thick before it lets go
    /// at `reach`; it is the same either way round.
    @Test func theNeckThinsToNothingBeforeItLetsGo() throws {
        let r1 = 19.0, r2 = 16.0, y = 28.0, c1 = 300.0
        func waist(_ neck: CancelBud.Neck) -> Double {
            let (a, b, c, d) = (neck.p1, neck.h1, neck.h3, neck.p3)
            return y - (a.y + 3 * b.y + 3 * c.y + d.y) / 8
        }
        var previous = Double.infinity
        for step in 0 ... 90 {
            let gap = Double(step) / 10 - 0.05
            let c2 = c1 - r1 - r2 - gap
            let neck = try #require(CancelBud.neck(body: c1, radius: r1, bud: c2, radius: r2, y: y))
            for point in [neck.p1, neck.p2] { #expect(Self.near(hypot(point.x - c1, point.y - y), r1)) }
            for point in [neck.p3, neck.p4] { #expect(Self.near(hypot(point.x - c2, point.y - y), r2)) }
            let thickness = waist(neck)
            if gap > 0 {
                #expect(thickness < previous + 1e-9)
                previous = thickness
            }
            #expect(thickness > 0)
            let mirrored = try #require(CancelBud.neck(body: -c1, radius: r1, bud: -c2, radius: r2, y: y))
            #expect(Self.near(mirrored.p1.x, -neck.p1.x) && Self.near(mirrored.p3.x, -neck.p3.x))
        }
        #expect(previous < 0.5)
        for gap in [CancelBud.reach, CancelBud.reach + 0.5, 30] {
            #expect(CancelBud.neck(body: c1, radius: r1, bud: c1 - r1 - r2 - gap, radius: r2, y: y) == nil)
        }
        #expect(CancelBud.neck(body: c1, radius: r1, bud: c1 - 2, radius: 7, y: y) == nil)
    }

    /// When toggle listening ends the pill takes the bud back: its × fades at once, it slips inside the pill's end,
    /// and is gone, asking for no more frames.
    @Test func thePillTakesTheBudBack() {
        var model = CancelBud.Model()
        model.update(resting: Self.resting, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: false, now: 0)
        model.update(resting: nil, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: true, now: 1)
        #expect((model.frame(at: 1 + Motion.handover, end: Self.end, endRadius: Self.endRadius, y: Self.y)?.glyphAlpha
            ?? 0) <= 0)
        var gone: Double?
        var inside = false
        for step in 0 ... 90 {
            let t = 1 + Double(step) / 60
            model.advance(to: t)
            if let frame = model.frame(at: t, end: Self.end, endRadius: Self.endRadius, y: Self.y) {
                if frame.centre + frame.radius <= Self.end { inside = true }
            } else if gone == nil {
                gone = t
            }
        }
        #expect(inside)
        #expect((gone ?? 99) >= 1.15 && (gone ?? 99) <= 2.5)
        #expect(!model.needsFrames(at: 2.5) && !model.isShowing)
    }

    /// With Reduce Motion nothing travels: the bud is simply there, then simply gone.
    @Test func reduceMotionMovesNothing() {
        var model = CancelBud.Model()
        model.update(resting: Self.resting, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: false, now: 1)
        #expect(model.frame(at: 1, end: Self.end, endRadius: Self.endRadius, y: Self.y)?.centre == Self.resting.centre)
        #expect(!model.needsFrames(at: 1))
        model.update(resting: nil, from: Self.end, to: Self.end, endRadius: Self.endRadius, animated: false, now: 2)
        #expect(model.frame(at: 2, end: Self.end, endRadius: Self.endRadius, y: Self.y) == nil)
        #expect(!model.needsFrames(at: 2))
    }
}

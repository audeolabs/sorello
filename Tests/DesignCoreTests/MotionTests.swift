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
        let from = PillBody(frame: CGRect(x: 838.5, y: 4, width: 59, height: 32), topRadius: 16, bottomRadius: 16)
        let to = PillBody(frame: CGRect(x: 738.5, y: 4, width: 259, height: 120), topRadius: 16, bottomRadius: 20)
        var body = MovingBody(from)
        body.move(to: to, at: 10)
        #expect(body.body(at: 10) == from)
        #expect(body.target == to)
        let at = body.body(at: 10.2)
        #expect(Double(at.frame.width) > 59 + 0.9 * 200)
        var widest = 0.0
        for step in 0 ... 200 {
            let frame = body.body(at: 10 + Double(step) / 200).frame
            widest = max(widest, Double(frame.width))
            #expect(frame.width >= 0 && frame.height >= 0)
        }
        #expect(widest - 259 < 1 && widest >= 259 - 0.01)
        #expect(body.isSettled(at: 11.5) && !body.isSettled(at: 10.1))
        #expect(body.body(at: 10.13) == body.body(at: 10.13))
        // Retargeted halfway, it carries on from where it is.
        let halfway = body.body(at: 10.1)
        body.move(to: from, at: 10.1)
        #expect(body.body(at: 10.1) == halfway)
        body.snap(to: to)
        #expect(body.body(at: 0) == to && body.isSettled(at: 0))
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
        model.update(resting: Self.resting, end: Self.end, endRadius: Self.endRadius, animated: true, now: 0)
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

    /// A bud resting beside the pill is never joined to it: the neck lets go before the resting gap.
    @Test func aBudBesideThePillHasNoNeck() {
        #expect(CancelBud.reach < PillGeometry.budGap)
        var model = CancelBud.Model()
        model.update(resting: Self.resting, end: Self.end, endRadius: Self.endRadius, animated: false, now: 0)
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
        model.update(resting: Self.resting, end: Self.end, endRadius: Self.endRadius, animated: false, now: 0)
        model.update(resting: nil, end: Self.end, endRadius: Self.endRadius, animated: true, now: 1)
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
        model.update(resting: Self.resting, end: Self.end, endRadius: Self.endRadius, animated: false, now: 1)
        #expect(model.frame(at: 1, end: Self.end, endRadius: Self.endRadius, y: Self.y)?.centre == Self.resting.centre)
        #expect(!model.needsFrames(at: 1))
        model.update(resting: nil, end: Self.end, endRadius: Self.endRadius, animated: false, now: 2)
        #expect(model.frame(at: 2, end: Self.end, endRadius: Self.endRadius, y: Self.y) == nil)
        #expect(!model.needsFrames(at: 2))
    }
}

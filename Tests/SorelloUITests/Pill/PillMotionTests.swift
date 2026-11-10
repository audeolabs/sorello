import AppKit
import DesignCore
@testable import SorelloUI
import Testing

/// ARCHITECTURE.md, section 8, "The pill" and "Motion": what the pill draws, moment by moment, as it drops down from
/// the band and goes back up, read from its layers at fixed moments on its motion clock. Nothing here puts a window on
/// the screen.
@MainActor
@Suite struct PillMotionTests {
    static let hold = PillDisplay.listening(.init(trigger: .hold, started: 0))
    static let screens = PillSnapshots.Housing.allCases.map(\.topology)

    /// A view over the whole of `screen`, its motion clock at 0, showing nothing yet.
    static func view(on screen: ScreenTopology, appearance: PillAppearance = PillAppearance()) -> PillView {
        let view = PillView(levels: nil, clock: { 0 }, fixedMotionTime: 0)
        view.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        view.update(PillScene(display: .hidden, screen: screen), appearance: appearance, animated: false)
        return view
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX - b.minX, a.minY - b.minY, a.maxX - b.maxX, a.maxY - b.maxY].allSatisfy { abs($0) < 1e-6 }
    }

    /// Appearing, the body starts as the rest, unseen, touching the foot of the band, and drops down to its place,
    /// fading in as it grows; hidden, it holds still while what it holds fades, then goes back up the same way and
    /// comes to rest only once it has faded. On no frame does it, or the cancel bud, reach into the band.
    @Test func thePillDropsDownAndGoesBackUp() throws {
        let toggle = PillDisplay.listening(.init(trigger: .toggle, started: 0))
        for screen in Self.screens {
            for display in [Self.hold, toggle] { try Self.dropsDownAndGoesBackUp(display, on: screen) }
        }
    }

    static func dropsDownAndGoesBackUp(_ display: PillDisplay, on screen: ScreenTopology) throws {
        let view = Self.view(on: screen)
        var rests: [Double] = []
        view.onRest = { rests.append(view.fixedMotionTime ?? -1) }
        let rest = PillGeometry.layout(.rest, on: screen).body.frame
        let layout = PillScene(display: display, screen: screen).layout
        let target = layout.cancel.map { layout.body.frame.union($0) } ?? layout.body.frame
        view.update(PillScene(display: display, screen: screen), appearance: PillAppearance(), animated: true)
        let first = try #require(view.drawnBody)
        #expect(Self.near(first.frame, rest) && first.opacity == 0, "it does not start as the rest, unseen")
        var opacity = 0.0, highest = Double.infinity
        // Two seconds: the bud sets out once the body has dropped, on its own softer spring.
        for step in 1 ... 240 {
            view.fixedMotionTime = Double(step) / 120
            let drawn = try #require(view.drawnBody)
            highest = min(highest, Double(drawn.frame.minY))
            #expect(drawn.opacity >= opacity, "it dimmed as it appeared")
            opacity = drawn.opacity
        }
        let settled = try #require(view.drawnBody)
        #expect(Self.near(settled.frame, target) && settled.opacity == 1)

        view.update(PillScene(display: .hidden, screen: screen), appearance: PillAppearance(), animated: true)
        view.fixedMotionTime = 2 + Motion.handover * 0.9
        let holding = try #require(view.drawnBody).frame
        #expect([holding.minY - target.minY, holding.minX - target.minX, holding.maxY - target.maxY]
            .allSatisfy { abs($0) < 1e-6 }, "it moved before what it holds had faded")
        for step in 1 ... 240 {
            view.fixedMotionTime = 2 + Double(step) / 120
            let drawn = try #require(view.drawnBody)
            highest = min(highest, Double(drawn.frame.minY))
            #expect(drawn.opacity <= opacity, "it brightened as it left")
            opacity = drawn.opacity
        }
        #expect(highest >= Double(rest.minY) - 1e-6, "it reached \(Double(rest.minY) - highest) pt into the band")
        let gone = try #require(view.drawnBody)
        #expect(Self.near(gone.frame, rest) && gone.opacity == 0)
        #expect(rests.count == 1)
        #expect((rests.first ?? 0) >= 2 + Motion.handover + Motion.appear, "it came to rest before it had faded")
    }

    /// In toggle mode the cancel bud waits until the body has dropped onto its line, then buds off its end and rests
    /// in its place; before that nothing is drawn beyond the body.
    @Test func theBudBudsOffOnceThePillHasDropped() throws {
        let screen = PillSnapshots.Housing.island.topology
        let toggle = PillDisplay.listening(.init(trigger: .toggle, started: 0))
        let layout = PillScene(display: toggle, screen: screen).layout
        let cancel = try #require(layout.cancel)
        let view = Self.view(on: screen)
        view.update(PillScene(display: toggle, screen: screen), appearance: PillAppearance(), animated: true)
        for step in 0 ..< 12 {
            view.fixedMotionTime = Double(step) / 120
            let drawn = try #require(view.drawnBody)
            #expect(drawn.frame.maxX <= layout.body.frame.maxX + 1e-6, "the bud showed before the body had dropped")
            #expect(drawn.frame.maxY <= layout.body.frame.maxY + 1e-6)
        }
        view.fixedMotionTime = 1.5
        let settled = try #require(view.drawnBody)
        #expect(abs(settled.frame.maxX - cancel.maxX) < 0.01 && abs(settled.frame.minX - layout.body.frame.minX) < 0.01)
    }

    /// A moment is drawn the same however the drawing was asked for: a press or a move of the panel redraws the pill's
    /// own moment, not the wall clock's, so the bud taken back as the pill hides is still there at the start.
    @Test func aRedrawKeepsThePillsMoment() throws {
        let screen = PillSnapshots.Housing.island.topology
        let toggle = PillDisplay.listening(.init(trigger: .toggle, started: 0))
        let cancel = try #require(PillScene(display: toggle, screen: screen).layout.cancel)
        let view = Self.view(on: screen)
        view.update(PillScene(display: toggle, screen: screen), appearance: PillAppearance(), animated: false)
        view.update(PillScene(display: .hidden, screen: screen), appearance: PillAppearance(), animated: true)
        view.pressed = .stop(dictation: 0)
        view.origin = CGPoint(x: 0, y: 0)
        let drawn = try #require(view.drawnBody)
        #expect(abs(drawn.frame.maxX - cancel.maxX) < 0.01, "the bud was taken back before its moment")
    }

    /// Shown and hidden in quick succession in toggle mode, the pill turns round wherever it is, and on no frame does
    /// any of it reach into the band.
    @Test func quickTurnsNeverReachIntoTheBand() throws {
        for screen in Self.screens {
            let toggle = PillDisplay.listening(.init(trigger: .toggle, started: 0))
            let foot = Double(PillGeometry.layout(.rest, on: screen).body.frame.minY)
            let view = Self.view(on: screen)
            let turns: [(Double, PillDisplay)] = [(0, toggle), (0.05, .hidden), (0.12, toggle), (0.3, .hidden),
                                                  (0.33, toggle), (0.7, .hidden), (0.95, toggle), (1.4, .hidden)]
            var highest = Double.infinity, next = 0
            for step in 0 ... 600 {
                let t = Double(step) / 240
                view.fixedMotionTime = t
                while next < turns.count, turns[next].0 <= t {
                    view.update(PillScene(display: turns[next].1, screen: screen), appearance: PillAppearance(),
                                animated: true)
                    next += 1
                }
                if let drawn = view.drawnBody, drawn.opacity > 0 { highest = min(highest, Double(drawn.frame.minY)) }
            }
            #expect(highest >= foot - 1e-6, "it reached \(foot - highest) pt into the band on \(screen)")
        }
    }

    /// With Reduce Motion nothing travels: the pill fades in at its place and, hidden, fades out there.
    @Test func withReduceMotionItFadesAtItsPlace() throws {
        let screen = PillSnapshots.Housing.island.topology, still = PillAppearance(reduceMotion: true)
        let view = Self.view(on: screen, appearance: still)
        var rested = false
        view.onRest = { rested = true }
        let target = PillScene(display: Self.hold, screen: screen).layout.body.frame
        view.update(PillScene(display: Self.hold, screen: screen), appearance: still, animated: true)
        for step in 0 ... 60 {
            view.fixedMotionTime = Double(step) / 120
            let drawn = try #require(view.drawnBody)
            #expect(Self.near(drawn.frame, target), "it travelled")
            #expect(abs(drawn.opacity - min(Double(step) / 120 / Motion.crossFade, 1)) < 0.01)
        }
        view.fixedMotionTime = 1
        view.update(PillScene(display: .hidden, screen: screen), appearance: still, animated: true)
        for step in 0 ... 60 {
            view.fixedMotionTime = 1 + Double(step) / 120
            let drawn = try #require(view.drawnBody)
            #expect(Self.near(drawn.frame, target), "it travelled")
            #expect(abs(drawn.opacity - max(1 - Double(step) / 120 / Motion.crossFade, 0)) < 0.01)
        }
        #expect(rested)
    }

    /// A pill called back while it is still going back up turns round from where it is, as bright as it was, and
    /// never comes to rest on the way.
    @Test func calledBackItTurnsRoundFromWhereItIs() throws {
        let screen = PillSnapshots.Housing.island.topology
        let view = Self.view(on: screen)
        var rested = false
        view.onRest = { rested = true }
        view.update(PillScene(display: Self.hold, screen: screen), appearance: PillAppearance(), animated: true)
        view.fixedMotionTime = 1
        view.update(PillScene(display: .hidden, screen: screen), appearance: PillAppearance(), animated: true)
        view.fixedMotionTime = 1.12
        let before = try #require(view.drawnBody)
        let again = PillDisplay.listening(.init(trigger: .hold, started: 1.12))
        view.update(PillScene(display: again, screen: screen), appearance: PillAppearance(), animated: true)
        let after = try #require(view.drawnBody)
        #expect(Self.near(before.frame, after.frame) && abs(before.opacity - after.opacity) < 1e-6)
        #expect(after.opacity > 0 && after.opacity < 1)
        view.fixedMotionTime = 2
        let settled = try #require(view.drawnBody)
        #expect(Self.near(settled.frame, PillScene(display: again, screen: screen).layout.body.frame))
        #expect(settled.opacity == 1 && !rested)
    }
}

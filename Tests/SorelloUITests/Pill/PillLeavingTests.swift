import AppKit
import DesignCore
@testable import SorelloUI
import Testing

/// ARCHITECTURE.md, section 8, "Motion": what leaves the pill stays where it was drawn while it fades, whatever size
/// the next form is and however the panel grows to hold it. The view is driven as the overlay drives it, its panel
/// sized from the real geometry, and what it draws is read from its layers at fixed moments on its motion clock.
/// Nothing here puts a window on the screen.
@MainActor
@Suite struct PillLeavingTests {
    static let screens = PillSnapshots.Housing.allCases.map(\.topology)

    static func notice(_ id: UInt64, _ text: String, actions: [String] = []) -> PillDisplay {
        .notice(.init(id: id, symbol: "info.circle", tone: .information, text: text,
                      actions: actions.map { .init(id: $0, title: $0) }))
    }

    /// One line, no actions: a card of the narrowest width.
    static let short = notice(1, "An invented line.")
    /// As wide as `short`, and taller: a row of actions below its line.
    static let taller = notice(2, "Another invented line.", actions: ["One", "Two"])
    /// Wider than both, and as tall as `taller`.
    static let wider = notice(3, "An invented line that runs on for long enough to widen the card.",
                              actions: ["One", "Two", "Three"])
    /// Wide enough to widen the panel, and one line tall.
    static let wide = notice(4, "An invented notice whose single line runs on wide enough to widen the panel.")
    /// No wider than `wide`, and taller: a row of four actions below its line.
    static let tall = notice(5, "Invented.", actions: ["One", "Two", "Three", "Four"])

    static func keys(_ displays: PillDisplay...) -> [PillContent.Key] { displays.compactMap { PillContent.Key($0) } }

    /// Wider and taller than all of them: its actions take two rows.
    static let tallest = notice(6, "Invented.", actions: ["An invented first choice", "An invented second choice",
                                                          "A third choice", "A fourth choice"])

    static let hold = PillDisplay.listening(.init(trigger: .hold, started: PillSnapshots.started))
    static let prompt = PillDisplay.listening(.init(trigger: .hold, promptStyle: true, started: PillSnapshots.started))

    /// A pill view in a panel sized as the overlay sizes it (`PillOverlayController.place`): covering the rest, the
    /// form shown and the one before it, with room for the spring and the edge, on whole points, and only ever growing
    /// while the pill is up. Each change sets the view's frame, then its origin (the same one when the panel's
    /// top-left corner did not move), then shows the display.
    @MainActor
    final class Panel {
        let view = PillView(levels: nil, clock: { PillSnapshots.started + 12 }, fixedWave: PillSnapshots.speech,
                            fixedMotionTime: 0)
        let screen: ScreenTopology
        let appearance: PillAppearance
        /// The part of the screen the panel covers, in screen points, after each display shown.
        private(set) var canvases: [CGRect] = []
        private var canvas: CGRect?

        init(on screen: ScreenTopology, appearance: PillAppearance) {
            self.screen = screen
            self.appearance = appearance
        }

        /// Grows the panel for `display`, as the overlay does before it shows it.
        func grow(for display: PillDisplay) {
            let next = PillScene(display: display, screen: screen, elapsed: 12)
            let rest = PillGeometry.layout(.rest, on: screen).body.frame
            let frames = [rest, next.layout.body.frame, next.layout.cancel ?? rest,
                          view.scene?.layout.body.frame ?? rest]
            var wanted = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -16)
            wanted = wanted.intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
            wanted = CGRect(x: wanted.minX.rounded(.down), y: wanted.minY.rounded(.down),
                            width: wanted.maxX.rounded(.up) - wanted.minX.rounded(.down),
                            height: wanted.maxY.rounded(.up) - wanted.minY.rounded(.down))
            let grown = canvas.map { $0.union(wanted) } ?? wanted
            canvases.append(grown)
            guard grown != canvas else { return }
            canvas = grown
            view.frame = CGRect(origin: .zero, size: grown.size)
            view.origin = grown.origin
        }

        func show(_ display: PillDisplay) {
            view.update(PillScene(display: display, screen: screen, elapsed: 12), appearance: appearance,
                        animated: true)
        }
    }

    /// Lays the view out, as AppKit does when its frame has changed, whenever that is.
    static func layOut(_ view: PillView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// A form seen leaving: what it drew just before, and its fade.
    struct Watched {
        var key: PillContent.Key
        var marks: [CGRect]
        var from: Double
        var opacity: Double
    }

    /// Plays `steps` on a panel, drawing every 1/240 s from 0 to `until`, and holds each form that leaves to the
    /// contract at every moment drawn, and, `layingOut`, whenever the view has been laid out: from the moment it begins
    /// to leave until it is gone, everything it draws stays where it was drawn just before, at the opacity its fade
    /// gives it, and it is gone only once that fade has ended. `inBody` also holds it inside the body's outline.
    /// Returns the panel, and the forms it saw leave.
    @discardableResult
    static func play(_ steps: [(time: Double, display: PillDisplay)], on screen: ScreenTopology,
                     appearance: PillAppearance = PillAppearance(), until: Double, layingOut: Bool = false,
                     inBody: Bool = false) -> (panel: Panel, watched: [Watched]) {
        let panel = Panel(on: screen, appearance: appearance)
        let view = panel.view
        let fade = appearance.reduceMotion ? Motion.crossFade : Motion.handover
        var watched: [Watched] = []

        func check(at t: Double, _ when: String) {
            for form in watched {
                let end = form.from + fade
                guard let drawn = view.drawnForms.first(where: { $0.leaving && $0.key == form.key }) else {
                    #expect(t >= end - 1e-9, "\(form.key) was gone \(end - t) s before its fade ended, \(when)")
                    continue
                }
                #expect(t < end + 1e-9, "\(form.key) was still drawn \(t - end) s after its fade ended, \(when)")
                let expected = form.opacity * max(1 - (t - form.from) / fade, 0)
                #expect(abs(drawn.opacity - expected) < 1e-3,
                        "\(form.key) is at opacity \(drawn.opacity), not \(expected), \(when)")
                #expect(drawn.marks.count == form.marks.count, "\(form.key) draws other things, \(when)")
                for (now, then) in zip(drawn.marks, form.marks) where !PillMotionTests.near(now, then) {
                    Issue.record("""
                        \(form.key) moved by (\(now.minX - then.minX), \(now.minY - then.minY)) pt on the screen \
                        \(t - form.from) s into its fade, \(when), on the \(screen.width) pt screen
                        """)
                    break
                }
                if inBody, drawn.opacity > 0, let body = view.drawnBody?.frame.insetBy(dx: -1e-6, dy: -1e-6) {
                    let outside = drawn.marks.filter { !body.contains($0) }
                    #expect(outside.isEmpty, "\(form.key) is drawn outside the body at \(outside), \(when)")
                }
            }
        }

        var next = 0
        for step in 0 ... Int((until * 240).rounded()) {
            let t = Double(step) / 240
            view.fixedMotionTime = t
            check(at: t, "drawn at \(t) s")
            if layingOut {
                layOut(view)
                check(at: t, "laid out at \(t) s")
            }
            while next < steps.count, steps[next].time <= t {
                let before = view.drawnForms.first { !$0.leaving }
                panel.grow(for: steps[next].display)
                if layingOut {
                    layOut(view)
                    check(at: t, "laid out as the panel grew at \(t) s")
                }
                panel.show(steps[next].display)
                if let before, view.drawnForms.contains(where: { $0.leaving && $0.key == before.key }) {
                    watched.append(Watched(key: before.key, marks: before.marks, from: t, opacity: before.opacity))
                }
                check(at: t, "as step \(next) was shown at \(t) s")
                if layingOut {
                    layOut(view)
                    check(at: t, "laid out after it was shown at \(t) s")
                }
                next += 1
            }
        }
        return (panel, watched)
    }

    /// A notice gives way to a taller notice that is no wider: the panel grows downward only, its top-left corner
    /// where it was, and the notice that leaves fades where it was drawn, inside the body.
    @Test func aNoticeGivingWayToATallerOneFadesWhereItWasDrawn() {
        for screen in Self.screens {
            let first = PillScene(display: Self.short, screen: screen).layout.body.frame
            let second = PillScene(display: Self.taller, screen: screen).layout.body.frame
            #expect(second.width <= first.width && second.height > first.height)
            let (panel, watched) = Self.play([(0, Self.short), (1, Self.taller)], on: screen, until: 1.2, inBody: true)
            #expect(watched.map(\.key) == Self.keys(Self.short))
            #expect(watched.first?.opacity == 1 && watched.first?.marks.isEmpty == false)
            let (before, after) = (panel.canvases[0], panel.canvases[1])
            #expect(after.origin == before.origin && after.width == before.width && after.height > before.height,
                    "the panel did not grow downward only: \(before) to \(after)")
        }
    }

    /// The wave and the time, and the wait's row and its words, give way to a tall notice in a panel an earlier, wider
    /// notice has already widened: the panel grows downward only, and every dot, the aurora dot, the time, the tag and
    /// the words fade where they were drawn.
    @Test func theWaveAndTheWaitFadeWhereTheyWereDrawn() {
        for screen in Self.screens {
            let wide = PillScene(display: Self.wide, screen: screen).layout.body.frame
            let tall = PillScene(display: Self.tall, screen: screen).layout.body.frame
            #expect(tall.width <= wide.width && tall.height > wide.height)
            for form in [Self.hold, Self.prompt, .waiting(.transcribing), .waiting(.preparingModel)] {
                let (panel, watched) = Self.play([(0, Self.wide), (1, form), (2, Self.tall)], on: screen, until: 2.2)
                #expect(watched.map(\.key) == Self.keys(Self.wide, form))
                #expect((watched.last?.marks.count ?? 0) > 2, "\(form) drew too little to be held to anything")
                let (before, after) = (panel.canvases[1], panel.canvases[2])
                #expect(after.origin == before.origin && after.width == before.width && after.height > before.height,
                        "the panel did not grow downward only: \(before) to \(after)")
            }
        }
    }

    /// A notice still fading out when the panel grows left, right and down for the next change, less than the fade's
    /// length later, stays where it was drawn, and so does the one that was arriving.
    @Test func whatIsAlreadyLeavingStaysWhereItWasDrawn() {
        for screen in Self.screens {
            let (panel, watched) = Self.play([(0, Self.short), (1, Self.taller), (1.02, Self.tallest)], on: screen,
                                             until: 1.2)
            #expect(watched.map(\.key) == Self.keys(Self.short, Self.taller))
            let (before, after) = (panel.canvases[1], panel.canvases[2])
            #expect(after.minX < before.minX && after.minY == before.minY && after.maxY > before.maxY,
                    "the panel did not grow left and down: \(before) to \(after)")
        }
    }

    /// Several changes inside one fade, each growing the panel, with the view laid out between and after them, as
    /// AppKit may do at any of those moments: nothing leaving moves.
    @Test func growingInStepsMovesNothingThatIsLeaving() {
        for screen in Self.screens {
            let steps: [(time: Double, display: PillDisplay)] = [(0, Self.short), (1, Self.taller), (1.015, Self.hold),
                                                                 (1.03, Self.wider), (1.045, Self.tallest)]
            let (panel, watched) = Self.play(steps, on: screen, until: 1.2, layingOut: true)
            #expect(watched.count == 4)
            let heights = panel.canvases.map(\.height)
            #expect(heights[1] > heights[0] && heights[4] > heights[3], "the panel did not grow at each step: \(heights)")
        }
    }

    /// With Reduce Motion the forms cross-fade in 0.15 s, and what leaves stays where it was drawn all that time.
    @Test func withReduceMotionWhatLeavesFadesWhereItWasDrawn() {
        let still = PillAppearance(reduceMotion: true)
        for screen in Self.screens {
            let once = Self.play([(0, Self.short), (1, Self.taller)], on: screen, appearance: still, until: 1.3,
                                 inBody: true)
            #expect(once.watched.count == 1)
            let twice = Self.play([(0, Self.wide), (1, Self.hold), (2, Self.tall), (2.05, Self.tallest)], on: screen,
                                  appearance: still, until: 2.4, layingOut: true)
            #expect(twice.watched.count == 3)
        }
    }
}

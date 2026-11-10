import AppKit
import DesignCore
@testable import SorelloUI
import Testing

/// ARCHITECTURE.md, section 8, "The pill": what each display offers, where its controls are and what VoiceOver
/// calls them, and how the overlay's windows behave. Nothing here puts a window on the screen.
@MainActor
@Suite struct PillOverlayTests {
    static let island = PillSnapshots.Housing.island.topology
    static let screens = PillSnapshots.Housing.allCases.map(\.topology)

    static func scene(_ display: PillDisplay, on screen: ScreenTopology = island) -> PillScene {
        PillScene(display: display, screen: screen)
    }

    /// In toggle mode the pill itself is Stop and the cancel bud is Cancel, named for VoiceOver; holding to talk, the
    /// pill takes no clicks at all, and neither does the wait.
    @Test func toggleModeOffersStopAndCancel() throws {
        for screen in Self.screens {
            let toggle = Self.scene(.listening(.init(trigger: .toggle, started: 0)), on: screen)
            #expect(toggle.controls.map(\.kind) == [.stop(dictation: 0), .cancel(dictation: 0)])
            let stop = try #require(toggle.controls.first), cancel = try #require(toggle.controls.last)
            #expect(stop.frame == toggle.layout.body.frame)
            #expect(cancel.frame == toggle.layout.cancel)
            #expect(stop.label == "Stop dictation" && cancel.label == "Cancel dictation")
            #expect(!stop.frame.intersects(cancel.frame))
            for display in [PillDisplay.listening(.init(trigger: .hold, started: 0)), .waiting(.transcribing),
                            .waiting(.preparingModel), .hidden] {
                #expect(Self.scene(display, on: screen).controls.isEmpty)
            }
        }
    }

    /// A notice's actions are controls inside its card, at most four, each reporting the notice's id and its own.
    @Test func noticeActionsAreControlsInTheCard() throws {
        let actions = (1 ... 5).map { PillDisplay.Notice.Action(id: "a\($0)", title: "Choice \($0)") }
        for screen in Self.screens {
            let scene = Self.scene(.notice(.init(id: 9, symbol: "info.circle", tone: .information,
                                                 text: "An invented message", actions: actions)), on: screen)
            let card = try #require(scene.layout.card)
            #expect(scene.controls.count == 4)
            for (index, control) in scene.controls.enumerated() {
                #expect(control.kind == .action(notice: 9, id: "a\(index + 1)"))
                #expect(control.label == "Choice \(index + 1)")
                #expect(card.contains(control.frame))
            }
        }
    }

    /// The pill holds still as the seconds tick and widens only when the time gains a digit, at ten minutes, about
    /// the same middle: what follows the wave is measured for the widest time with as many digits as the one shown,
    /// so it always holds the time and leaves no empty digit beside it.
    @Test func thePillWidensOnlyWhenTheTimeGainsADigit() throws {
        func layout(_ elapsed: Double, prompt: Bool = false) -> PillLayout {
            PillScene(display: .listening(.init(trigger: .hold, promptStyle: prompt, started: 1_000)),
                      screen: Self.island, elapsed: elapsed).layout
        }
        for prompt in [false, true] {
            let early = layout(0, prompt: prompt), late = layout(600, prompt: prompt)
            #expect((0 ..< 600).allSatisfy { layout(Double($0) + 0.5, prompt: prompt) == early }, "it moved early on")
            #expect((600 ..< 900).allSatisfy { layout(Double($0) + 0.5, prompt: prompt) == late }, "it moved later on")
            #expect(late.body.frame.width > early.body.frame.width)
            #expect(abs(late.body.frame.midX - early.body.frame.midX) <= 0.25)
        }
        for second in 0 ..< 900 {
            let text = PillScene.elapsedText(Double(second))
            let box = try #require(layout(Double(second)).trailing)
            #expect(PillType.width(of: text, font: PillType.time) <= box.width, "\(text) does not fit")
        }
        #expect(try #require(layout(12).trailing).width == PillType.width(of: "0:00", font: PillType.time))
        #expect(PillScene.timeGainsADigit(after: 0) == 600)
        #expect(PillScene.timeGainsADigit(after: 599.9) == 600)
        #expect(PillScene.timeGainsADigit(after: 600) == 6_000)
        #expect(PillScene.timeGainsADigit(after: -5) == 600 && PillScene.timeGainsADigit(after: .nan) == 600)
        #expect(PillScene.elapsedText(0) == "0:00")
        #expect(PillScene.elapsedText(7.9) == "0:07")
        #expect(PillScene.elapsedText(61) == "1:01")
        #expect(PillScene.elapsedText(14 * 60 + 59.99) == "14:59")
        #expect(PillScene.elapsedText(-3) == "0:00")
        #expect(PillScene.elapsedText(.nan) == "0:00")
    }

    /// The words of the wait fit their box on every screen, and a hidden pill is at its rest under the band.
    @Test func theWaitsWordsFitAndHiddenRests() throws {
        for screen in Self.screens {
            let preparing = Self.scene(.waiting(.preparingModel), on: screen)
            let words = PillType.width(of: PillScene.preparingText, font: PillType.words)
            #expect(try #require(preparing.layout.trailing).width >= words)
            let hidden = Self.scene(.hidden, on: screen)
            #expect(hidden.layout == PillGeometry.layout(.rest, on: screen))
        }
    }

    /// The drawing panel ignores the mouse, the controls panel sits above it and takes clicks; neither ever becomes
    /// key or main, both join every Space and show over full-screen apps, at the status bar's level.
    @Test func thePanelsNeverTakeFocus() {
        let drawing = OverlayPanel(interactive: false), controls = OverlayPanel(interactive: true)
        #expect(drawing.ignoresMouseEvents && !controls.ignoresMouseEvents)
        #expect(drawing.level == .statusBar && controls.level.rawValue > drawing.level.rawValue)
        for panel in [drawing, controls] {
            #expect(!panel.canBecomeKey && !panel.canBecomeMain)
            #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
            #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(!panel.hidesOnDeactivate && !panel.isOpaque && !panel.hasShadow)
        }
    }

    /// VoiceOver sees each control as a button with the pill's name for it and can press it; the drawing, the moving
    /// level included, is not exposed at all.
    @Test func voiceOverSeesButtonsAndNoLevel() {
        var activated: [PillControl.Kind] = []
        let scene = Self.scene(.listening(.init(trigger: .toggle, started: 0)))
        for control in scene.controls {
            let target = ControlTarget()
            target.onActivate = { activated.append($0) }
            target.control = control
            #expect(target.accessibilityRole() == .button && target.isAccessibilityElement())
            #expect(target.accessibilityLabel() == control.label)
            _ = target.accessibilityPerformPress()
        }
        #expect(activated == [.stop(dictation: 0), .cancel(dictation: 0)])

        let pill = PillView(levels: LevelFeed(), clock: { 0 })
        pill.update(Self.scene(.listening(.init(trigger: .hold, started: 0))), appearance: PillAppearance(),
                    animated: false)
        #expect(pill.accessibilityChildren()?.isEmpty == true)
        #expect(!pill.isAccessibilityElement())
        #expect(pill.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// A click acts on release inside the control it began on. A press held while the notice changes under it is
    /// abandoned, so the new notice's action is never taken by a press meant for the old one.
    @Test func aPressBelongsToTheControlItBeganOn() throws {
        let first = PillControl(kind: .action(notice: 1, id: "add"), frame: CGRect(x: 0, y: 0, width: 60, height: 26),
                                label: "Add")
        let next = PillControl(kind: .action(notice: 2, id: "never"), frame: first.frame, label: "Never")
        let target = ControlTarget(frame: first.frame)
        var activated: [PillControl.Kind] = [], pressed: [PillControl.Kind?] = []
        target.onActivate = { activated.append($0) }
        target.onPress = { pressed.append($0) }
        target.control = first
        let down = try #require(Self.mouse(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        let up = try #require(Self.mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10)))
        let away = try #require(Self.mouse(.leftMouseUp, at: NSPoint(x: 200, y: 10)))
        target.mouseDown(with: down)
        target.mouseUp(with: up)
        #expect(activated == [first.kind])
        target.mouseDown(with: down)
        target.mouseUp(with: away)
        #expect(activated == [first.kind], "a release outside acted")
        target.mouseDown(with: down)
        target.control = next
        target.mouseUp(with: up)
        #expect(activated == [first.kind], "a press carried over to the next notice")
        #expect(pressed.last == .some(nil))
        // Stop held as one dictation ends and the next begins, its Stop in the same place: the release stops nothing.
        let stopA = PillControl(kind: .stop(dictation: 10), frame: first.frame, label: "Stop dictation")
        let stopB = PillControl(kind: .stop(dictation: 20), frame: first.frame, label: "Stop dictation")
        target.control = stopA
        target.mouseDown(with: down)
        target.control = stopB
        target.mouseUp(with: up)
        target.control = stopA
        target.mouseDown(with: down)
        target.control = nil
        target.control = stopA
        target.mouseUp(with: up)
        #expect(activated == [first.kind], "a press survived its dictation or its panel leaving")
    }

    /// Shows `display` and returns the step (a mutating call cannot sit inside `#expect`).
    @discardableResult
    static func show(_ life: inout OverlayLifecycle, _ display: PillDisplay) -> OverlayLifecycle.Step? {
        life.show(display)
    }

    static func rest(_ life: inout OverlayLifecycle) -> Bool { life.rested() }

    /// The overlay chooses a screen when a dictation starts, even if the pill never left the last one, and keeps it
    /// for that dictation's wait and notices. Appearing, the controls take no clicks until the pill has dropped into
    /// place and what it holds has arrived; a change while it is up offers them at once.
    @Test func eachDictationChoosesItsScreen() {
        var life = OverlayLifecycle()
        let first = PillDisplay.listening(.init(trigger: .hold, started: 10))
        let second = PillDisplay.listening(.init(trigger: .hold, started: 20))
        let arriving = OverlayLifecycle.arrival
        #expect(arriving >= Motion.drop + Motion.arrival)
        #expect(Self.show(&life, first) == .init(chooseScreen: true, present: true, controlsAfter: arriving))
        #expect(Self.show(&life, .waiting(.transcribing)) == .init(chooseScreen: false, present: true))
        #expect(Self.show(&life, Self.notice) == .init(chooseScreen: false, present: true))
        #expect(Self.show(&life, second) == .init(chooseScreen: true, present: true))
        #expect(Self.show(&life, .listening(.init(trigger: .hold, promptStyle: false, started: 20)))
            == .init(chooseScreen: false, present: true))
        // A notice shown from nothing (a microphone that is denied) chooses a screen too.
        var idle = OverlayLifecycle()
        #expect(Self.show(&idle, Self.notice) == .init(chooseScreen: true, present: true, controlsAfter: arriving))
    }

    /// Hidden, the panels stay up only until the pill has come to rest, and nothing brings them back until something
    /// is shown: not a change of screens or accessibility settings, nor a rest reported late.
    @Test func hiddenPanelsStayOffUntilSomethingIsShown() {
        var life = OverlayLifecycle()
        #expect(Self.show(&life, .hidden) == nil)
        #expect(!life.appliesChanges)
        _ = Self.show(&life, .waiting(.transcribing))
        #expect(life.appliesChanges && !Self.rest(&life), "a pill that is up came to rest")
        #expect(Self.show(&life, .hidden) == .init(chooseScreen: false, present: false))
        #expect(life.appliesChanges, "a pill going back up stops following the screen")
        #expect(Self.rest(&life))
        #expect(!life.appliesChanges && life.phase == .off)
        #expect(!Self.rest(&life))
        #expect(Self.show(&life, .hidden) == nil)
        // Called back while going back up, it stays on its screen and does not come to rest.
        _ = Self.show(&life, .waiting(.transcribing))
        _ = Self.show(&life, .hidden)
        #expect(Self.show(&life, .waiting(.preparingModel))
            == .init(chooseScreen: false, present: true, controlsAfter: OverlayLifecycle.arrival))
        #expect(!Self.rest(&life))
    }

    /// The floating body's fade: appearing or hiding replaces any fade still running or waiting (a hide followed at once
    /// by a show never lets the old fade-out dim the new pill); a change of content while it fades in lets the fade
    /// finish; an update placed at once ends any fade.
    @Test func theBodysFadeFollowsVisibilityOnly() {
        #expect(PillView.bodyFade(wasShowing: false, showing: true, animated: true) == (cancel: true, start: true))
        #expect(PillView.bodyFade(wasShowing: true, showing: false, animated: true) == (cancel: true, start: true))
        #expect(PillView.bodyFade(wasShowing: true, showing: true, animated: true) == (cancel: false, start: false))
        #expect(PillView.bodyFade(wasShowing: false, showing: false, animated: true) == (cancel: false, start: false))
        #expect(PillView.bodyFade(wasShowing: true, showing: true, animated: false) == (cancel: true, start: false))
        #expect(PillView.bodyFade(wasShowing: false, showing: true, animated: false) == (cancel: true, start: false))
    }

    static let notice = PillDisplay.notice(.init(id: 5, symbol: "info.circle", tone: .information, text: "Invented"))

    /// The snapshot tool draws every state under a camera island, under a notch and with neither, a contact sheet, a
    /// 1x preview and the drop frame by frame for each, and the mark's pictures, each under its own name.
    @Test func everyStateHasASnapshot() {
        let names = PillSnapshots.scenes.map(\.name)
        #expect(Set(names).count == names.count)
        for housing in ["island", "notch", "none"] {
            for state in ["listening-silent", "listening-speaking", "listening-toggle", "listening-prompt", "waiting",
                          "waiting-preparing", "notice-error", "notice-suggestion", "notice-suggestion-app",
                          "notice-suggestion-long-app", "contrast-listening",
                          "reduce-motion-waiting", "contact-sheet", "toggle-at-1x", "drop"] {
                #expect(names.contains("pill-\(housing)-\(state)"))
            }
        }
        for mark in ["mark", "mark-menu-bar-light", "mark-menu-bar-dark", "mark-app-icon"] {
            #expect(names.contains(mark))
        }
        #expect(SorelloMarkImages.menuBarIcon().isTemplate)
    }
}

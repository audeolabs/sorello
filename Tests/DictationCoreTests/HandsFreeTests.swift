import DictationCore
import Foundation
import Testing

/// Rule 5 with the double tap set to a hands-free dictation, the default: two taps of Hold to Talk start a toggle
/// recording, and Hold to Talk tapped once more stops it at the release. Also the part of rule 5 that holds whatever
/// the setting: Hold to Talk stops any toggle recording.
@Suite("Rule 5: Hands-free double tap")
struct HandsFreeTests {
    private func startEffects(_ id: DictationID) -> [SessionEffect] {
        [.startCapture(id, CaptureRequest()), .openStream(id, retainForCorrection: false),
         .setTimer(.captureStart(id), after: SessionTiming.captureStart)]
    }

    private func stopEffects(_ id: DictationID) -> [SessionEffect] {
        [.stopCapture(id), .cancelTimer(.captureLimit(id)),
         .setTimer(.captureDrain(id), after: SessionTiming.captureDrain)]
    }

    /// Taps Hold to Talk at `time` and presses it again 0.3 s later. Returns the dictation the second press started.
    @discardableResult
    private func doubleTap(_ machine: inout Machine, at time: TimeInterval,
                           sourceLocation: SourceLocation = #_sourceLocation) -> DictationID? {
        machine.press(.hold, at: time, sourceLocation: sourceLocation)
        machine.release(at: time + 0.1, sourceLocation: sourceLocation)
        return machine.press(.hold, at: time + 0.3, sourceLocation: sourceLocation)
    }

    /// A hands-free dictation recording (id 2), started by a double tap at 10 s whose second press came up at 10.4 s.
    private func recordingHandsFree(_ settings: SessionSettings = SessionSettings(),
                                    sourceLocation: SourceLocation = #_sourceLocation) -> Machine {
        var machine = Machine(settings: settings)
        doubleTap(&machine, at: 10, sourceLocation: sourceLocation)
        machine.started(id2, sourceLocation: sourceLocation)
        machine.release(at: 10.4, sourceLocation: sourceLocation)
        return machine
    }

    private func expectRecording(_ machine: Machine, _ id: DictationID,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .recording(let live) = machine.state.capture else {
            Issue.record("not recording: \(machine.state.capture)", sourceLocation: sourceLocation)
            return
        }
        #expect(live.id == id && live.mode == .toggle, sourceLocation: sourceLocation)
    }

    // MARK: Starting

    @Test func theDefaultIsHandsFree() {
        #expect(SessionSettings().doubleTap == .handsFree)
    }

    @Test func aTapThenAPressStartsAPlainToggleRecording() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        #expect(machine.release(at: 10.1).discarded == [id1], "the tap is discarded")
        #expect(machine.state.tap?.releaseTime == 10.1)
        #expect(machine.trigger(.holdPressed, at: 10.4).effects == startEffects(id2))
        #expect(machine.state.capture.live?.mode == .toggle)
        #expect(machine.state.capture.live?.style == .plain)
        #expect(machine.state.capture.live?.pressTime == 10.4)
        #expect(machine.state.tap == nil, "the arm is used up")
    }

    @Test(arguments: [0.05, SessionTiming.tapHold, 5, 60])
    func releasingThePressThatStartedItStopsNothing(heldFor: TimeInterval) {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        machine.started(id2)
        let outcome = machine.trigger(.holdReleased(.keyUp), at: 10.3 + heldFor)
        #expect(outcome.effects.isEmpty)
        #expect(machine.state.tap == nil, "a hands-free start never arms")
        expectRecording(machine, id2)
        #expect(machine.trigger(.holdReleased(.keyUp), at: 200).effects.isEmpty, "a second release is ignored")
        expectRecording(machine, id2)
    }

    @Test func releasingItWhileStillStartingStopsNothing() {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        #expect(machine.release(at: 10.35).isEmpty)
        #expect(machine.started(id2) == [.cancelTimer(.captureStart(id2)),
                                         .setTimer(.captureLimit(id2), after: SessionTiming.captureLimit)])
        expectRecording(machine, id2)
    }

    @Test func itGoesOnUntilTheLimit() {
        var machine = recordingHandsFree()
        expectRecording(machine, id2)
        #expect(machine.fire(.captureLimit(id2)) == [.stopCapture(id2),
                                                     .setTimer(.captureDrain(id2), after: SessionTiming.captureDrain)])
    }

    // MARK: Stopping with Hold to Talk

    @Test(arguments: [0.05, 2])
    func aLaterTapStopsItAtTheRelease(heldFor: TimeInterval) {
        var machine = recordingHandsFree()
        let press = machine.trigger(.holdPressed, at: 20)
        #expect(press.effects.isEmpty, "nothing stops at the press")
        expectRecording(machine, id2)
        #expect(machine.release(at: 20 + heldFor) == stopEffects(id2))
        #expect(machine.state.capture == .idle)
        #expect(machine.state.stages == [Stage(id2, .draining(drainTimerArmed: true))])
        #expect(machine.state.tap == nil, "the stopping tap never arms")

        machine.ended(id2, audio: 9.5)
        #expect(machine.transcript(id2, "Invented words").inserts.map(\.style) == [.plain])
        machine.insertion(id2, .inserted, text: "Invented words")
        machine.expectSettled()
    }

    @Test func aTapWhileItIsStillStartingStopsItWhenItStarts() {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        machine.release(at: 10.35)
        #expect(machine.trigger(.holdPressed, at: 10.5).effects.isEmpty)
        #expect(machine.release(at: 10.6).isEmpty, "nothing to stop yet")
        #expect(machine.started(id2) == [.cancelTimer(.captureStart(id2)), .stopCapture(id2),
                                         .setTimer(.captureDrain(id2), after: SessionTiming.captureDrain)])
        #expect(machine.state.stages == [Stage(id2, .draining(drainTimerArmed: true))])
    }

    @Test func aStoppingPressAbandonedAsAChordStopsNothing() {
        var machine = recordingHandsFree()
        machine.trigger(.holdPressed, at: 20)
        let abandoned = machine.trigger(.holdAbandoned, at: 20.1)
        #expect(abandoned.effects.isEmpty)
        expectRecording(machine, id2)
        // A modifier-only binding delivers nothing more for an abandoned hold; whatever does come stops nothing.
        #expect(machine.release(at: 20.5).isEmpty)
        #expect(machine.release(at: 20.6, .interrupted).isEmpty)
        #expect(machine.trigger(.holdAbandoned, at: 20.7).effects.isEmpty)
        expectRecording(machine, id2)
        #expect(machine.state.tap == nil, "such a press never arms")

        machine.trigger(.holdPressed, at: 22)
        #expect(machine.release(at: 22.1) == stopEffects(id2), "the next genuine tap still stops it")
    }

    @Test func aStoppingPressEndedInterruptedStopsNothing() {
        var machine = recordingHandsFree()
        machine.trigger(.holdPressed, at: 20)
        #expect(machine.release(at: 20.1, .interrupted).isEmpty)
        expectRecording(machine, id2)
        #expect(machine.release(at: 20.2).isEmpty, "a later release belongs to no press")
        expectRecording(machine, id2)
        #expect(machine.state.tap == nil)

        machine.trigger(.holdPressed, at: 22)
        #expect(machine.release(at: 22.1) == stopEffects(id2), "the next genuine tap still stops it")
    }

    @Test(arguments: [false, true])
    func aStartingPressAbandonedAsAChordDiscardsTheRecording(startedFirst: Bool) {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        if startedFirst { machine.started(id2) }
        let outcome = machine.trigger(.holdAbandoned, at: 10.35)
        #expect(outcome.acted)
        #expect(outcome.effects.discarded == [id2])
        #expect(outcome.effects.shownNotices == 0)
        #expect(machine.state.notice == nil)
        #expect(machine.state.tap == nil)
        machine.expectSettled()
    }

    @Test func anAbandonedHoldAfterTheStartingPressCameUpDoesNothing() {
        var machine = recordingHandsFree()
        let outcome = machine.trigger(.holdAbandoned, at: 11)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        expectRecording(machine, id2)
    }

    @Test(arguments: DoubleTapAction.allCases)
    func aHoldToTalkTapStopsATapToToggleRecording(setting: DoubleTapAction) {
        var machine = Machine(settings: SessionSettings(doubleTap: setting))
        machine.press(.toggle, at: 10)
        machine.started(id1)
        #expect(machine.trigger(.holdPressed, at: 12).effects.isEmpty, "the press starts nothing")
        #expect(machine.state.capture.live?.id == id1)
        #expect(machine.release(at: 12.1) == stopEffects(id1))
        #expect(machine.state.tap == nil)
    }

    @Test func aHoldToTalkPressDuringAToggleRecordingThatEndsAnotherWayDoesNothingAtTheRelease() {
        let endings: [(String, (inout Machine) -> Void)] = [
            ("Tap to Toggle", { _ = $0.trigger(.togglePressed, at: 20.1) }),
            ("the pill", { _ = $0.trigger(.pillStopClicked, at: 20.1) }),
            ("Escape", { _ = $0.trigger(.cancelPressed, at: 20.1) }),
            ("the limit", { _ = $0.fire(.captureLimit(id2)) }),
            ("a system interruption", { _ = $0.trigger(.systemInterrupted, at: 20.1) }),
            ("a capture failure", { _ = $0.send(.capture(id2, .failed(.failed))) }),
        ]
        for (name, end) in endings {
            var machine = recordingHandsFree()
            machine.trigger(.holdPressed, at: 20)
            end(&machine)
            #expect(machine.state.capture == .idle, "\(name) ended it")
            let release = machine.trigger(.holdReleased(.keyUp), at: 20.2)
            #expect(!release.acted && release.effects.isEmpty, "the release after \(name) does nothing")
            #expect(machine.state.capture == .idle, "and starts nothing")
            #expect(machine.state.tap == nil)
        }
    }

    @Test func aHoldToTalkPressBeforeANewToggleRecordingDoesNotStopIt() {
        var machine = recordingHandsFree()
        machine.trigger(.holdPressed, at: 20)
        machine.trigger(.togglePressed, at: 20.1)
        #expect(machine.press(.toggle, at: 20.2) == id3)
        machine.started(id3)
        #expect(machine.release(at: 20.3).isEmpty, "the press came before this recording")
        expectRecording(machine, id3)
    }

    // MARK: Stopping and cancelling it like any toggle recording

    @Test(arguments: [TriggerEvent.togglePressed, .pillStopClicked, .systemInterrupted])
    func itStopsLikeAnyToggleRecording(trigger: TriggerEvent) {
        var machine = recordingHandsFree()
        #expect(machine.trigger(trigger, at: 20).effects == stopEffects(id2))
        #expect(machine.state.stages == [Stage(id2, .draining(drainTimerArmed: true))])
    }

    @Test(arguments: [TriggerEvent.cancelPressed, .pillCancelClicked])
    func itCancelsLikeAnyToggleRecording(trigger: TriggerEvent) {
        var machine = recordingHandsFree()
        let outcome = machine.trigger(trigger, at: 20)
        #expect(outcome.acted)
        #expect(outcome.effects.discarded == [id2])
        machine.expectSettled()
    }

    @Test func itsStartingPressStillDownWhenSomethingElseStopsItEndsQuietly() {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        machine.started(id2)
        machine.trigger(.pillStopClicked, at: 12)
        #expect(machine.state.stages == [Stage(id2, .draining(drainTimerArmed: true))])
        #expect(machine.release(at: 12.5).isEmpty, "the starting press comes up after the stop")
        #expect(machine.trigger(.holdAbandoned, at: 12.6).effects.isEmpty)
        #expect(machine.state.stages == [Stage(id2, .draining(drainTimerArmed: true))])
    }

    // MARK: What comes after

    @Test func aPressRightAfterTheStoppingTapIsAnOrdinaryHold() {
        var machine = recordingHandsFree()
        machine.trigger(.holdPressed, at: 20)
        machine.release(at: 20.1)
        #expect(machine.state.tap == nil)
        #expect(machine.press(.hold, at: 20.2) == id3)
        #expect(machine.state.capture.live?.mode == .hold)
        #expect(machine.state.capture.live?.style == .plain)
        machine.started(id3)
        #expect(machine.release(at: 22).contains(.stopCapture(id3)), "released like any hold")
    }

    @Test(arguments: [0.1, 0.3])
    func threeTapsInARowLeaveNothingBehind(audio: TimeInterval) {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        machine.release(at: 10.4)
        machine.trigger(.holdPressed, at: 10.55)
        machine.started(id2)
        #expect(machine.release(at: 10.65) == stopEffects(id2), "the third tap stops it")
        machine.ended(id2, audio: audio)
        if audio >= SessionTiming.minimumAudio { machine.transcript(id2, "") }
        #expect(machine.state.tap == nil)
        #expect(machine.state.notice == nil)
        #expect(machine.log.inserts.isEmpty)
        machine.expectSettled()
    }

    // MARK: The setting

    @Test func setToNothingAQuickHoldIsAnOrdinaryHoldAndTwoTapsStartNothingSpecial() {
        var machine = Machine(settings: SessionSettings(doubleTap: .off))
        machine.press(.hold, at: 10)
        machine.started(id1)
        #expect(machine.release(at: 10.1).contains(.stopCapture(id1)), "a quick hold is stopped, not discarded")
        #expect(machine.state.tap == nil)
        #expect(machine.press(.hold, at: 10.3) == id2)
        #expect(machine.state.capture.live?.mode == .hold)
        #expect(machine.state.capture.live?.style == .plain)
    }

    @Test func theSecondPressFollowsTheSettingAsItIsThen() {
        var toPrompt = Machine()
        toPrompt.press(.hold, at: 10)
        toPrompt.release(at: 10.1)
        toPrompt.settings.doubleTap = .prompt
        toPrompt.press(.hold, at: 10.3)
        #expect(toPrompt.state.capture.live?.mode == .hold)
        #expect(toPrompt.state.capture.live?.style == .prompt)

        var toHandsFree = Machine(settings: SessionSettings(doubleTap: .prompt))
        toHandsFree.press(.hold, at: 10)
        toHandsFree.release(at: 10.1)
        toHandsFree.settings.doubleTap = .handsFree
        toHandsFree.press(.hold, at: 10.3)
        #expect(toHandsFree.state.capture.live?.mode == .toggle)
        #expect(toHandsFree.state.capture.live?.style == .plain)

        var toNothing = Machine()
        toNothing.press(.hold, at: 10)
        toNothing.release(at: 10.1)
        toNothing.settings.doubleTap = .off
        toNothing.press(.hold, at: 10.3)
        #expect(toNothing.state.capture.live?.mode == .hold)
        #expect(toNothing.state.capture.live?.style == .plain)
        toNothing.started(id2)
        #expect(toNothing.release(at: 10.4).contains(.stopCapture(id2)), "an ordinary hold, not a tap")
    }

    @Test func turningItOffForgetsTheArm() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.release(at: 10.1)
        machine.settings.doubleTap = .off
        machine.send(.engine(.ready))
        machine.settings.doubleTap = .handsFree
        #expect(machine.state.tap == nil)
        machine.press(.hold, at: 10.3)
        #expect(machine.state.capture.live?.mode == .hold)
    }

    @Test func turningItOffDuringAHoldTakesItOutOfTheDoubleTap() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.settings.doubleTap = .off
        machine.send(.engine(.ready))
        machine.settings.doubleTap = .handsFree
        #expect(machine.release(at: 10.1).discarded.isEmpty, "released like any other hold")
        #expect(machine.state.tap == nil, "and it arms nothing")
    }

    @Test(arguments: [DoubleTapAction.prompt, .off])
    func aHandsFreeRecordingStaysOneWhateverTheSettingBecomes(setting: DoubleTapAction) {
        var machine = Machine()
        doubleTap(&machine, at: 10)
        machine.started(id2)
        machine.settings.doubleTap = setting
        machine.send(.engine(.ready))
        #expect(machine.release(at: 10.4).isEmpty, "its starting press still stops nothing")
        expectRecording(machine, id2)
        machine.trigger(.holdPressed, at: 20)
        #expect(machine.release(at: 20.1) == stopEffects(id2), "and Hold to Talk still stops it")
    }
}

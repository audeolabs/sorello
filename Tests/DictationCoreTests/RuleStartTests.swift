import DictationCore
import Foundation
import Testing

// Rules 1 to 4 of ARCHITECTURE.md, section 3: starting, permission, recording and stopping.

private let startEffects: [SessionEffect] = [
    .startCapture(id1, CaptureRequest()),
    .openStream(id1, retainForCorrection: false),
    .setTimer(.captureStart(id1), after: SessionTiming.captureStart),
]

@Suite("Rule 1: Start")
struct RuleStartTests {
    @Test func aHoldPressWhileIdleStartsADictation() {
        var machine = Machine()
        let outcome = machine.trigger(.holdPressed, at: 10)
        #expect(outcome.acted)
        #expect(outcome.effects == startEffects)
        #expect(machine.state.capture.live?.id == id1)
        #expect(machine.state.capture.live?.mode == .hold)
        #expect(machine.state.capture.live?.style == .plain)
        #expect(machine.state.capture.live?.pressTime == 10)
    }

    @Test func aTogglePressWhileIdleStartsAToggleDictation() {
        var machine = Machine()
        #expect(machine.trigger(.togglePressed, at: 10).effects == startEffects)
        #expect(machine.state.capture.live?.mode == .toggle)
    }

    @Test func theChosenMicrophoneAndRetentionAreReadAtTheStart() {
        var machine = Machine(settings: SessionSettings(microphoneID: "mic-a", retainForCorrection: true))
        let effects = machine.trigger(.holdPressed, at: 10).effects
        #expect(effects.contains(.startCapture(id1, CaptureRequest(deviceID: "mic-a"))))
        #expect(effects.contains(.openStream(id1, retainForCorrection: true)))
    }

    /// Section 6, "Audio capture": the Bluetooth switch is read with the chosen microphone, and is on unless turned off.
    @Test func theBluetoothSwitchIsReadAtTheStart() {
        #expect(SessionSettings().avoidBluetoothMicrophone)
        #expect(CaptureRequest().avoidBluetooth)
        var on = Machine()
        #expect(on.trigger(.holdPressed, at: 10).effects.contains(.startCapture(id1, CaptureRequest(avoidBluetooth: true))))
        var off = Machine(settings: SessionSettings(microphoneID: "mic-a", avoidBluetoothMicrophone: false))
        #expect(off.trigger(.holdPressed, at: 10).effects
            .contains(.startCapture(id1, CaptureRequest(deviceID: "mic-a", avoidBluetooth: false))))
    }

    @Test func idsOnlyGrow() {
        var machine = Machine()
        let first = machine.recordHold(at: 10)
        let second = machine.recordHold(at: 20)
        #expect(first == id1 && second == id2)
    }

    @Test func aPressWithThreeDictationsShowsTheBusyNoticeAndStartsNothing() {
        var machine = Machine()
        machine.recordHold(at: 10)
        machine.recordHold(at: 20)
        machine.recordHold(at: 30)
        #expect(machine.state.dictationCount == 3)
        let outcome = machine.trigger(.togglePressed, at: 40)
        #expect(outcome.effects.startedDictation == nil)
        #expect(machine.state.capture == .idle)
        #expect(machine.state.notice?.message == .busy)
    }

    @Test func aPressWithTwoDictationsStartsTheThird() {
        var machine = Machine()
        machine.recordHold(at: 10)
        machine.recordHold(at: 20)
        #expect(machine.press(.hold, at: 30) == id3)
        #expect(machine.state.dictationCount == 3)
    }

    @Test func aDeniedMicrophoneShowsItsNoticeAndStartsNothing() {
        var machine = Machine(microphone: .denied)
        let outcome = machine.trigger(.holdPressed, at: 10)
        #expect(outcome.effects.startedDictation == nil)
        #expect(!outcome.effects.contains(.requestMicrophoneAccess))
        #expect(machine.state.capture == .idle)
        #expect(machine.state.notice?.message == .microphoneDenied)
    }

    @Test func aFailedEngineShowsItsNoticeAndStartsNothing() {
        var machine = Machine(engine: .failed(.modelCorrupt))
        let outcome = machine.trigger(.togglePressed, at: 10)
        #expect(outcome.effects.startedDictation == nil)
        #expect(machine.state.notice?.message == .engineFailed(.modelCorrupt))
    }

    @Test func anEngineStillPreparingDoesNotBlockRecording() {
        var machine = Machine(engine: .preparing)
        #expect(machine.press(.hold, at: 10) == id1)
    }

    @Test func startingDismissesTheNotice() throws {
        var machine = Machine()
        let quiet = machine.recordHold(at: 10, for: 1.5)
        machine.transcript(quiet, "")
        let notice = try #require(machine.state.notice)
        let effects = machine.trigger(.holdPressed, at: 20).effects
        #expect(machine.state.notice == nil)
        #expect(effects.contains(.cancelTimer(.notice(notice.id))))
    }
}

@Suite("Rule 2: Permission")
struct RulePermissionTests {
    /// The tests that compare a whole hold intent use a double tap set to nothing, so the intent they build matches
    /// one that takes no part in the double tap (rule 5).
    private static let noDoubleTap = SessionSettings(doubleTap: .off)

    @Test func aPressWithUnknownAccessRequestsItAndHoldsTheIntent() {
        var machine = Machine(microphone: .unknown, settings: Self.noDoubleTap)
        let outcome = machine.trigger(.holdPressed, at: 10)
        #expect(outcome.acted)
        #expect(outcome.effects == [.requestMicrophoneAccess])
        #expect(machine.state.capture == .awaitingPermission(PermissionIntent(mode: .hold, pressTime: 10)))
    }

    @Test func accessGrantedStartsTheIntentAsPressed() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.togglePressed, at: 10)
        let effects = machine.send(.microphoneAccess(.granted))
        #expect(effects == startEffects)
        #expect(machine.state.microphone == .granted)
        #expect(machine.state.capture.live?.mode == .toggle)
        #expect(machine.state.capture.live?.pressTime == 10)
    }

    @Test func aGrantNeverRevivesAReleasedHold() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.holdPressed, at: 10)
        #expect(machine.release(at: 11).isEmpty)
        #expect(machine.state.capture == .awaitingPermission(nil))
        #expect(machine.send(.microphoneAccess(.granted)).isEmpty)
        #expect(machine.state.capture == .idle)
        machine.expectSettled()
    }

    @Test func anAbandonedHoldClearsTheIntent() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.holdPressed, at: 10)
        #expect(machine.trigger(.holdAbandoned, at: 10.1).acted)
        #expect(machine.send(.microphoneAccess(.granted)).isEmpty)
        machine.expectSettled()
    }

    @Test func aSecondTogglePressClearsTheIntentAndAThirdSetsItAgain() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.togglePressed, at: 10)
        machine.trigger(.togglePressed, at: 11)
        #expect(machine.state.capture == .awaitingPermission(nil))
        machine.trigger(.togglePressed, at: 12)
        #expect(machine.state.capture == .awaitingPermission(PermissionIntent(mode: .toggle, pressTime: 12)))
        #expect(machine.log.filter { $0 == .requestMicrophoneAccess }.count == 1, "asked once")
    }

    @Test func escapeClearsTheIntentAndIsConsumed() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.holdPressed, at: 10)
        #expect(machine.trigger(.cancelPressed, at: 10.5).acted)
        #expect(machine.state.capture == .awaitingPermission(nil))
        #expect(!machine.trigger(.cancelPressed, at: 10.6).acted, "nothing left to cancel")
        #expect(machine.send(.microphoneAccess(.granted)).isEmpty)
    }

    @Test func aSystemInterruptionClearsTheIntent() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.togglePressed, at: 10)
        machine.trigger(.systemInterrupted, at: 11)
        #expect(machine.send(.microphoneAccess(.granted)).isEmpty)
        machine.expectSettled()
    }

    @Test func aNewPressReplacesTheIntent() {
        var machine = Machine(microphone: .unknown, settings: Self.noDoubleTap)
        machine.trigger(.holdPressed, at: 10)
        machine.release(at: 10.5)
        machine.trigger(.holdPressed, at: 12)
        #expect(machine.state.capture == .awaitingPermission(PermissionIntent(mode: .hold, pressTime: 12)))
        machine.trigger(.togglePressed, at: 13)
        #expect(machine.state.capture == .awaitingPermission(PermissionIntent(mode: .toggle, pressTime: 13)))
        machine.send(.microphoneAccess(.granted))
        #expect(machine.state.capture.live?.mode == .toggle)
        #expect(machine.state.capture.live?.pressTime == 13)
    }

    @Test func accessDeniedClearsTheIntentAndShowsTheMicrophoneNotice() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.holdPressed, at: 10)
        let effects = machine.send(.microphoneAccess(.denied))
        #expect(effects.startedDictation == nil)
        #expect(machine.state.capture == .idle)
        #expect(machine.state.microphone == .denied)
        #expect(machine.state.notice?.message == .microphoneDenied)
    }

    @Test func aGrantWhileTheEngineHasFailedShowsTheEngineNotice() {
        var machine = Machine(microphone: .unknown)
        machine.trigger(.holdPressed, at: 10)
        machine.send(.engine(.failed(.loadFailed)))
        let effects = machine.send(.microphoneAccess(.granted))
        #expect(effects.startedDictation == nil)
        #expect(machine.state.capture == .idle)
        #expect(machine.state.notice?.message == .engineFailed(.loadFailed))
    }

    @Test func anUndecidedAnswerKeepsWaiting() {
        var machine = Machine(microphone: .unknown, settings: Self.noDoubleTap)
        machine.trigger(.holdPressed, at: 10)
        #expect(machine.send(.microphoneAccess(.unknown)).isEmpty)
        #expect(machine.state.capture == .awaitingPermission(PermissionIntent(mode: .hold, pressTime: 10)))
    }

    @Test func accessReadOutsideAPromptOnlyUpdatesTheMicrophone() {
        var machine = Machine(microphone: .denied)
        #expect(machine.send(.microphoneAccess(.granted)).isEmpty)
        #expect(machine.state.capture == .idle)
        #expect(machine.press(.hold, at: 10) == id1)
    }
}

@Suite("Rule 3: Recording")
struct RuleRecordingTests {
    @Test func startedMovesToRecordingAndArmsTheLimit() throws {
        var machine = Machine()
        machine.press(.hold, at: 10)
        let effects = machine.started(id1)
        #expect(effects == [.cancelTimer(.captureStart(id1)),
                            .setTimer(.captureLimit(id1), after: SessionTiming.captureLimit)])
        #expect(machine.state.capture == .recording(try #require(machine.state.capture.live)))
    }

    @Test func aReleaseDuringStartingIsAppliedWhenTheCaptureStarts() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        #expect(machine.release(at: 11).isEmpty, "nothing to stop yet")
        let effects = machine.started(id1)
        #expect(effects == [.cancelTimer(.captureStart(id1)), .stopCapture(id1),
                            .setTimer(.captureDrain(id1), after: SessionTiming.captureDrain)])
        #expect(machine.state.capture == .idle)
        #expect(machine.state.pipeline.map(\.phase) == [.draining(drainTimerArmed: true)])
    }

    @Test func aSecondTogglePressDuringStartingIsAppliedWhenTheCaptureStarts() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        #expect(machine.trigger(.togglePressed, at: 10.5).acted)
        #expect(machine.started(id1).contains(.stopCapture(id1)))
        #expect(machine.state.pipeline.map(\.id) == [id1])
    }

    @Test func aStartedReportWhileRecordingOrDrainingDoesNothing() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        #expect(machine.started(id1).isEmpty)
        machine.release(at: 12)
        #expect(machine.started(id1).isEmpty)
    }
}

@Suite("Rule 4: Stop")
struct RuleStopTests {
    private static let stopEffects: [SessionEffect] = [
        .stopCapture(id1), .cancelTimer(.captureLimit(id1)),
        .setTimer(.captureDrain(id1), after: SessionTiming.captureDrain),
    ]

    private func recording(_ mode: TriggerMode, settings: SessionSettings = SessionSettings()) -> Machine {
        var machine = Machine(settings: settings)
        machine.press(mode, at: 10)
        machine.started(id1)
        return machine
    }

    private func expectStopped(_ machine: Machine, _ effects: [SessionEffect],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(effects == Self.stopEffects, sourceLocation: sourceLocation)
        #expect(machine.state.capture == .idle, sourceLocation: sourceLocation)
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))], sourceLocation: sourceLocation)
    }

    @Test func releasingHoldToTalkStops() {
        var machine = recording(.hold)
        let effects = machine.release(at: 12)
        expectStopped(machine, effects)
    }

    @Test func aGenuineOrInterruptedReleaseBothStop() {
        var machine = recording(.hold)
        let effects = machine.release(at: 12, .interrupted)
        expectStopped(machine, effects)
    }

    @Test func pressingTapToToggleAgainStops() {
        var machine = recording(.toggle)
        let effects = machine.trigger(.togglePressed, at: 12).effects
        expectStopped(machine, effects)
    }

    @Test func clickingThePillInToggleModeStops() {
        var machine = recording(.toggle)
        let effects = machine.trigger(.pillStopClicked, at: 12).effects
        expectStopped(machine, effects)
    }

    @Test func clickingThePillInHoldModeDoesNothing() {
        var machine = recording(.hold)
        let outcome = machine.trigger(.pillStopClicked, at: 12)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        #expect(machine.state.capture.live?.id == id1)
    }

    @Test func theLimitTimerStopsWithoutCancellingItself() {
        var machine = recording(.toggle)
        let effects = machine.fire(.captureLimit(id1))
        #expect(effects == [.stopCapture(id1), .setTimer(.captureDrain(id1), after: SessionTiming.captureDrain)])
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))])
    }

    @Test func aSystemInterruptionStops() {
        var machine = recording(.toggle)
        let effects = machine.trigger(.systemInterrupted, at: 12).effects
        expectStopped(machine, effects)
    }

    @Test(arguments: [CaptureReport.stalled, .interrupted(.deviceRemoved), .interrupted(.systemSleep),
                      .failed(.failed)])
    func aCaptureProblemWhileRecordingStops(_ report: CaptureReport) {
        var machine = recording(.hold)
        let effects = machine.send(.capture(id1, report))
        expectStopped(machine, effects)
    }

    @Test func theMicrophoneCanBeAskedForAgainAtOnce() {
        var machine = recording(.hold)
        machine.release(at: 12)
        #expect(machine.press(.hold, at: 12.1) == id2)
    }

    @Test func captureEndedFinishesADrainingDictation() {
        var machine = recording(.hold)
        machine.release(at: 12)
        let effects = machine.ended(id1, audio: 2)
        #expect(effects == [.cancelTimer(.captureDrain(id1)), .finishStream(id1)])
        #expect(machine.state.pipeline.map(\.phase) == [.transcribing(audio: 2)])
    }

    @Test func tooLittleAudioIsDiscardedWithoutANotice() {
        // A hold this short would be a tap of the double tap (rule 5), so the double tap is set to nothing.
        var machine = recording(.hold, settings: SessionSettings(doubleTap: .off))
        machine.release(at: 10.1)
        let effects = machine.ended(id1, audio: 0.1)
        #expect(effects == [.cancelTimer(.captureDrain(id1)), .discard(id1),
                            .complete(DictationCompletion(id: id1, ending: .discarded))])
        #expect(machine.state.notice == nil)
        machine.expectSettled()
    }

    @Test func exactlyTheMinimumIsTranscribed() {
        // A hold this short would be a tap of the double tap (rule 5), so the double tap is set to nothing.
        var machine = recording(.hold, settings: SessionSettings(doubleTap: .off))
        machine.release(at: 10.2)
        #expect(machine.ended(id1, audio: SessionTiming.minimumAudio).contains(.finishStream(id1)))
    }

    @Test func theDrainTimerOnlyAborts() {
        var machine = recording(.hold)
        machine.release(at: 12)
        #expect(machine.fire(.captureDrain(id1)) == [.abortCapture(id1)])
        #expect(machine.state.pipeline.map(\.phase) == [.draining(drainTimerArmed: false)])
        #expect(machine.ended(id1, audio: 2) == [.finishStream(id1)], "the fired timer is not cancelled")
    }

    @Test func aCaptureEventWhileDrainingOtherThanEndedDoesNothing() {
        var machine = recording(.hold)
        machine.release(at: 12)
        for report in [CaptureReport.started, .stalled, .interrupted(.deviceRemoved), .failed(.failed)] {
            #expect(machine.send(.capture(id1, report)).isEmpty)
        }
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))])
    }

    @Test func aCaptureEventForADictationPastDrainingDoesNothing() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        for report in [CaptureReport.started, .stalled, .failed(.failed), .ended(CaptureSummary(duration: 3))] {
            #expect(machine.send(.capture(id, report)).isEmpty, "transcribing")
        }
        machine.transcript(id, "Invented words")
        for report in [CaptureReport.stalled, .ended(CaptureSummary(duration: 3))] {
            #expect(machine.send(.capture(id, report)).isEmpty, "inserting")
        }
    }

    @Test func aCaptureThatEndsWhileRecordingGoesStraightToItsTranscript() {
        var machine = recording(.toggle)
        let effects = machine.ended(id1, audio: 4)
        #expect(effects == [.stopCapture(id1), .cancelTimer(.captureLimit(id1)), .finishStream(id1)])
        #expect(machine.state.capture == .idle)
        #expect(machine.state.pipeline.map(\.phase) == [.transcribing(audio: 4)])
    }
}

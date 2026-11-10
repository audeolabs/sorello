import DictationCore
import Foundation
import Testing

/// Rule 5, the prompt double tap. Ported from the double-tap detector's tests in the reference material, restated
/// as triggers into `Session.reduce`: the detector's state is now the session's `tap` and the live dictation.
/// Tests of the old app's queued arrival stamps, capture tickets and audio files are not ported: here every
/// trigger is reduced in arrival order and capture work is the runtime's.
@Suite("Rule 5: Double tap")
struct DoubleTapTests {
    private static let on = SessionSettings(promptMode: true)

    private func machine(promptMode: Bool = true) -> Machine {
        Machine(settings: SessionSettings(promptMode: promptMode))
    }

    /// The style of the dictation a press started, or nil if it started none.
    private func pressStyle(_ machine: inout Machine, at time: TimeInterval,
                            sourceLocation: SourceLocation = #_sourceLocation) -> DictationStyle? {
        guard machine.press(.hold, at: time, sourceLocation: sourceLocation) != nil else { return nil }
        return machine.state.capture.live?.style
    }

    /// Releases the hold and says whether the dictation was discarded as a tap.
    private func releaseDiscards(_ machine: inout Machine, at time: TimeInterval, _ origin: ReleaseOrigin = .keyUp,
                                 sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard let id = machine.state.capture.live?.id else {
            Issue.record("no hold to release", sourceLocation: sourceLocation)
            return false
        }
        return machine.release(at: time, origin, sourceLocation: sourceLocation).discarded == [id]
    }

    @Test func aTapThenAPressStartsAPromptDictation() {
        var machine = machine()
        #expect(pressStyle(&machine, at: 10) == .plain, "a first press is a normal hold")
        #expect(releaseDiscards(&machine, at: 10.1), "a 0.1 s hold is a tap, discarded")
        #expect(machine.state.tap?.releaseTime == 10.1)
        #expect(pressStyle(&machine, at: 10.4) == .prompt, "a press 0.3 s later starts prompt style")
        #expect(machine.state.tap == nil, "the arm is used up")
        #expect(!releaseDiscards(&machine, at: 12), "the prompt dictation is long enough to transcribe")
    }

    @Test func aTapReleasedWhileStartingStillArms() {
        var machine = machine()
        machine.press(.hold, at: 10)
        #expect(releaseDiscards(&machine, at: 10.1), "discarded although the capture never started")
        #expect(pressStyle(&machine, at: 10.3) == .prompt)
    }

    @Test func aLatePressIsANormalHold() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        #expect(releaseDiscards(&machine, at: 10.1))
        #expect(pressStyle(&machine, at: 10.51) == .plain, "0.41 s after the release is a normal hold")
        #expect(!releaseDiscards(&machine, at: 11), "a normal hold")
        #expect(machine.state.tap == nil, "the expired arm leaves nothing behind")
    }

    @Test func aLongFirstHoldNeitherArmsNorIsDiscarded() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        #expect(!releaseDiscards(&machine, at: 10.5), "a 0.5 s hold is transcribed")
        #expect(machine.state.tap == nil, "and does not arm")
    }

    @Test func boundariesAreInclusiveWhereTheRuleSaysSo() {
        var exact = machine()
        _ = pressStyle(&exact, at: 0)
        #expect(!releaseDiscards(&exact, at: SessionTiming.tapHold), "exactly 0.3 s is not a tap")
        #expect(exact.state.tap == nil)

        var window = machine()
        _ = pressStyle(&window, at: -0.1)
        #expect(releaseDiscards(&window, at: 0))
        #expect(pressStyle(&window, at: SessionTiming.tapWindow) == .prompt, "exactly 0.4 s counts")
        #expect(SessionTiming.tapHold == 0.3 && SessionTiming.tapWindow == 0.4)
    }

    @Test func boundariesHoldAtAnyPointOnTheTimeline() {
        var hold = machine()
        _ = pressStyle(&hold, at: 100.0)
        #expect(!releaseDiscards(&hold, at: 100.3), "100.0 to 100.3 is exactly the minimum, not a tap")

        var window = machine()
        _ = pressStyle(&window, at: 10.0)
        #expect(releaseDiscards(&window, at: 10.1))
        #expect(pressStyle(&window, at: 10.5) == .prompt, "10.1 to 10.5 is exactly the window")

        var late = machine()
        _ = pressStyle(&late, at: 1000.0)
        #expect(releaseDiscards(&late, at: 1000.2999), "just under the minimum is a tap")
        #expect(pressStyle(&late, at: 1000.7000001) == .plain, "just past the window is a normal hold")
    }

    @Test func withPromptModeOffNothingChanges() {
        var machine = machine(promptMode: false)
        _ = pressStyle(&machine, at: 10)
        machine.started(id1)
        #expect(!releaseDiscards(&machine, at: 10.05), "no minimum hold when off")
        machine.ended(id1, audio: 0.05)
        #expect(pressStyle(&machine, at: 10.1) == .plain, "no prompt style when off")
    }

    @Test func anotherTriggerBetweenTheTapAndThePressClearsTheArm() {
        for other in [TriggerEvent.pasteAgainPressed, .cancelPressed, .pillCancelClicked, .pillStopClicked,
                      .systemInterrupted, .holdReleased(.keyUp), .holdAbandoned] {
            var machine = machine()
            _ = pressStyle(&machine, at: 10)
            _ = releaseDiscards(&machine, at: 10.1)
            machine.trigger(other, at: 10.2)
            #expect(pressStyle(&machine, at: 10.3) == .plain, "\(other) clears the arm")
        }
    }

    @Test func aTogglePressBetweenTheTapAndThePressPreventsThePromptDictation() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        _ = releaseDiscards(&machine, at: 10.1)
        #expect(machine.press(.toggle, at: 10.2) == id2, "the toggle press starts its own dictation")
        #expect(machine.press(.hold, at: 10.3) == nil, "the hold press is ignored during a toggle recording")
        machine.trigger(.cancelPressed, at: 10.4)
        #expect(pressStyle(&machine, at: 10.45) == .plain, "and the arm is gone")
    }

    @Test func anotherTriggerDuringTheFirstHoldStopsItArming() {
        var toggled = machine()
        _ = pressStyle(&toggled, at: 20)
        #expect(!toggled.trigger(.togglePressed, at: 20.05).acted, "ignored during a hold")
        #expect(releaseDiscards(&toggled, at: 20.1), "still a tap, so discarded")
        #expect(toggled.state.tap == nil, "but it does not arm")

        var pasted = machine()
        _ = pressStyle(&pasted, at: 20)
        pasted.trigger(.pasteAgainPressed, at: 20.05)
        #expect(releaseDiscards(&pasted, at: 20.1))
        #expect(pressStyle(&pasted, at: 20.2) == .plain)
    }

    @Test func escapeDuringTheFirstHoldEndsTheDoubleTap() {
        var machine = machine()
        _ = pressStyle(&machine, at: 20)
        #expect(machine.trigger(.cancelPressed, at: 20.05).effects.discarded == [id1])
        #expect(machine.release(at: 20.1).isEmpty, "the release of a cancelled hold is ignored")
        #expect(pressStyle(&machine, at: 20.2) == .plain)
    }

    @Test func aChordEndsTheDoubleTap() {
        var first = machine()
        _ = pressStyle(&first, at: 20)
        first.trigger(.holdAbandoned, at: 20.1)
        #expect(pressStyle(&first, at: 20.2) == .plain, "a chord on the first press never arms")

        var second = machine()
        _ = pressStyle(&second, at: 20)
        _ = releaseDiscards(&second, at: 20.1)
        #expect(pressStyle(&second, at: 20.2) == .prompt)
        #expect(second.trigger(.holdAbandoned, at: 20.25).effects.discarded == [id2], "the chord discards it")
        #expect(pressStyle(&second, at: 20.3) == .plain, "and nothing is armed")
    }

    @Test func onlyAGenuineKeyUpArms() {
        var interrupted = machine()
        _ = pressStyle(&interrupted, at: 1.0)
        #expect(releaseDiscards(&interrupted, at: 1.1, .interrupted), "still a tap, so discarded")
        #expect(pressStyle(&interrupted, at: 1.3) == .plain, "but an interrupted release never arms")

        var genuine = machine()
        _ = pressStyle(&genuine, at: 1.0)
        _ = releaseDiscards(&genuine, at: 1.1)
        #expect(pressStyle(&genuine, at: 1.3) == .prompt)
    }

    @Test func aHoldThatStartedWhileBusyNeverArms() {
        var machine = machine()
        let older = machine.recordHold(at: 1)
        _ = pressStyle(&machine, at: 10)
        #expect(releaseDiscards(&machine, at: 10.1), "a tap is discarded even while busy")
        #expect(machine.state.tap == nil, "but it arms only from idle")
        #expect(pressStyle(&machine, at: 10.2) == .plain)
        #expect(machine.state.stages.first?.id == older)
    }

    @Test func aPromptHoldNeverArms() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        _ = releaseDiscards(&machine, at: 10.1)
        #expect(pressStyle(&machine, at: 10.2) == .prompt)
        #expect(releaseDiscards(&machine, at: 10.25), "a quick prompt hold is discarded")
        #expect(pressStyle(&machine, at: 10.3) == .plain, "and never arms another tap")
    }

    @Test func turningPromptModeOffForgetsTheArm() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        _ = releaseDiscards(&machine, at: 10.1)
        machine.settings.promptMode = false
        machine.send(.engine(.ready))
        machine.settings.promptMode = true
        #expect(machine.state.tap == nil)
        #expect(pressStyle(&machine, at: 10.2) == .plain)
    }

    @Test func thePromptStyleStaysWithItsDictationAndTheNextOneIsPlain() {
        var machine = machine()
        _ = pressStyle(&machine, at: 10)
        _ = releaseDiscards(&machine, at: 10.1)
        guard let prompt = machine.press(.hold, at: 10.3) else {
            Issue.record("no prompt dictation")
            return
        }
        machine.started(prompt)
        machine.release(at: 12)
        machine.ended(prompt, audio: 1.7)
        #expect(machine.transcript(prompt, "Invented request").inserts.map(\.style) == [.prompt])
        machine.insertion(prompt, .inserted, text: "Invented request")
        #expect(pressStyle(&machine, at: 20) == .plain)
    }

    @Test func triggersBeforeTheFirstPressDoNotMatter() {
        var machine = machine()
        machine.trigger(.pasteAgainPressed, at: 1.0)
        _ = pressStyle(&machine, at: 1.1)
        _ = releaseDiscards(&machine, at: 1.2)
        #expect(pressStyle(&machine, at: 1.4) == .prompt)
    }
}

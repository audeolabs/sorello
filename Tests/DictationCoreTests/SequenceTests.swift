import DictationCore
import Foundation
import Testing

/// Sequences a user actually produces, event by event. Each ends with nothing in flight (`expectSettled`): no
/// capture or stream open, the output free, every dictation completed once, and only the dictations that should be
/// transcribed or inserted were.
@Suite("Sequences")
struct SequenceTests {
    @Test func aQuickTap() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 10.08)
        machine.ended(id1, audio: 0.08)
        #expect(machine.state.notice == nil)
        #expect(machine.log.inserts.isEmpty && !machine.log.contains(.finishStream(id1)))
        machine.expectSettled()
    }

    @Test func releaseDuringStarting() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.release(at: 10.6)
        machine.started(id1)
        machine.ended(id1, audio: 0.4)
        machine.transcript(id1, "Invented")
        machine.insertion(id1, .inserted, text: "Invented")
        #expect(machine.log.inserts.map(\.id) == [id1])
        machine.expectSettled()
    }

    @Test func pressAgainWhileThePreviousDictationDrains() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 12)
        #expect(machine.press(.hold, at: 12.2) == id2, "the microphone is free at once")
        machine.started(id2)
        machine.ended(id1)
        machine.release(at: 14)
        machine.ended(id2)
        machine.transcript(id1, "First")
        machine.transcript(id2, "Second")
        machine.insertion(id1, .inserted, text: "First")
        machine.insertion(id2, .inserted, text: "Second")
        #expect(machine.log.inserts.map(\.id) == [id1, id2])
        machine.expectSettled()
    }

    @Test func theSecondTranscriptArrivingFirstIsStillInsertedSecond() {
        var machine = Machine()
        let first = machine.recordHold(at: 10)
        let second = machine.recordHold(at: 13)
        machine.transcript(second, "Second")
        machine.transcript(first, "First")
        machine.insertion(first, .inserted, text: "First")
        machine.insertion(second, .inserted, text: "Second")
        #expect(machine.log.inserts.map(\.id) == [first, second])
        #expect(machine.state.lastText == "Second")
        machine.expectSettled()
    }

    @Test func aThirdDictationWhileTwoWaitAndAFourthRefused() {
        var machine = Machine()
        machine.recordHold(at: 10)
        machine.recordHold(at: 13)
        #expect(machine.press(.toggle, at: 16) == id3)
        machine.started(id3)
        #expect(machine.press(.hold, at: 17) == nil, "a hold press during a toggle recording")
        machine.trigger(.togglePressed, at: 18)
        #expect(machine.press(.hold, at: 18.5) == nil, "the fourth is refused")
        #expect(machine.state.notice?.message == .busy)
        machine.ended(id3)
        for id in [id1, id2, id3] { machine.transcript(id, "Words \(id.rawValue)") }
        for id in [id1, id2, id3] { machine.insertion(id, .inserted, text: "Words \(id.rawValue)") }
        #expect(machine.log.inserts.map(\.id) == [id1, id2, id3])
        machine.expectSettled()
    }

    @Test func escapeWhileRecordingWithAnOlderItemTranscribing() {
        var machine = Machine()
        let older = machine.recordHold(at: 10)
        machine.press(.hold, at: 13)
        machine.started(id2)
        machine.trigger(.cancelPressed, at: 14)
        machine.release(at: 14.5)
        machine.transcript(older, "Older")
        machine.insertion(older, .inserted, text: "Older")
        #expect(machine.log.inserts.map(\.id) == [older])
        machine.expectSettled()
    }

    @Test func escapeWhileOneItemInsertsAndAnotherTranscribes() {
        var machine = Machine()
        let inserting = machine.recordHold(at: 10)
        let transcribing = machine.recordHold(at: 13)
        machine.transcript(inserting, "Kept")
        #expect(machine.trigger(.cancelPressed, at: 16).effects.discarded == [transcribing])
        #expect(machine.transcript(transcribing, "Late").isEmpty, "its transcript is stale")
        machine.insertion(inserting, .inserted, text: "Kept")
        #expect(machine.log.inserts.map(\.id) == [inserting])
        machine.expectSettled()
    }

    @Test func escapeWhileDraining() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 12)
        let effects = machine.trigger(.cancelPressed, at: 12.1).effects
        #expect(effects.contains(.cancelTimer(.captureDrain(id1))))
        #expect(effects.discarded == [id1])
        #expect(machine.ended(id1).isEmpty, "the end of a discarded capture is stale")
        machine.expectSettled()
    }

    @Test func thePromptAnsweredAfterTheKeyWasReleased() {
        var machine = Machine(microphone: .unknown)
        machine.press(.hold, at: 10)
        machine.release(at: 10.4)
        machine.send(.microphoneAccess(.granted))
        #expect(machine.log.startedDictation == nil)
        machine.expectSettled()
    }

    @Test func thePromptAnsweredAfterAReleaseAndANewPress() {
        var machine = Machine(microphone: .unknown)
        machine.press(.hold, at: 10)
        machine.release(at: 10.4)
        machine.press(.hold, at: 11)
        machine.send(.microphoneAccess(.granted))
        #expect(machine.state.capture.live?.pressTime == 11, "the press still down starts")
        machine.started(id1)
        machine.release(at: 13)
        machine.ended(id1)
        machine.transcript(id1, "Invented")
        machine.insertion(id1, .inserted, text: "Invented")
        machine.expectSettled()
    }

    @Test func thePromptAnsweredAfterAToggleWasPressedTwice() {
        var machine = Machine(microphone: .unknown)
        machine.press(.toggle, at: 10)
        machine.press(.toggle, at: 11)
        machine.send(.microphoneAccess(.granted))
        #expect(machine.log.startedDictation == nil)
        machine.expectSettled()
    }

    @Test func aCaptureThatFinishesStartingAfterItsDictationWasCancelled() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        machine.trigger(.cancelPressed, at: 10.2)
        #expect(machine.started(id1).isEmpty, "the late start is stale; the runtime aborts the capture")
        machine.expectSettled()
    }

    @Test func theDrainTimerAndTheLastAudioInEitherOrder() {
        var endedFirst = Machine()
        endedFirst.press(.hold, at: 10)
        endedFirst.started(id1)
        endedFirst.release(at: 12)
        endedFirst.ended(id1)
        #expect(endedFirst.fire(.captureDrain(id1)).isEmpty, "a queued drain timer after the end does nothing")
        endedFirst.transcript(id1, "Invented")
        endedFirst.insertion(id1, .inserted, text: "Invented")
        endedFirst.expectSettled()

        var timerFirst = Machine()
        timerFirst.press(.hold, at: 10)
        timerFirst.started(id1)
        timerFirst.release(at: 12)
        #expect(timerFirst.fire(.captureDrain(id1)) == [.abortCapture(id1)])
        #expect(timerFirst.ended(id1) == [.finishStream(id1)], "what was delivered is still transcribed")
        timerFirst.transcript(id1, "Invented")
        timerFirst.insertion(id1, .inserted, text: "Invented")
        timerFirst.expectSettled()
        #expect(endedFirst.log.filter { $0 == .finishStream(id1) }.count == 1)
        #expect(timerFirst.log.filter { $0 == .finishStream(id1) }.count == 1)
    }

    @Test func cancellingANewDictationWhileAnOlderOneDrains() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 12)
        machine.press(.toggle, at: 12.1)
        #expect(machine.trigger(.cancelPressed, at: 12.2).effects.discarded == [id2])
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))])
        machine.ended(id1)
        machine.transcript(id1, "Older")
        machine.insertion(id1, .inserted, text: "Older")
        machine.expectSettled()
    }

    @Test(arguments: [CaptureReport.stalled, .interrupted(.deviceRemoved)])
    func aCaptureProblemWithATailOfAudio(_ problem: CaptureReport) {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        machine.started(id1)
        machine.send(.capture(id1, problem))
        #expect(machine.state.capture == .idle)
        #expect(machine.ended(id1, audio: 6) == [.cancelTimer(.captureDrain(id1)), .finishStream(id1)])
        machine.transcript(id1, "Up to the problem")
        machine.insertion(id1, .inserted, text: "Up to the problem")
        machine.expectSettled()
    }

    @Test func systemInterruptionInEveryPhase() {
        var starting = Machine()
        starting.press(.hold, at: 10)
        starting.trigger(.systemInterrupted, at: 10.1)
        starting.release(at: 10.5)
        starting.expectSettled()

        for mode in [TriggerMode.hold, .toggle] {
            var recording = Machine()
            recording.press(mode, at: 10)
            recording.started(id1)
            recording.trigger(.systemInterrupted, at: 12)
            if mode == .hold { recording.release(at: 30, .interrupted) }
            #expect(recording.state.capture == .idle, "nothing resumes")
            recording.ended(id1)
            recording.transcript(id1, "Before the lock")
            recording.insertion(id1, .leftOnClipboard(.screenLocked), text: "Before the lock")
            recording.expectSettled()
        }

        var awaiting = Machine(microphone: .unknown)
        awaiting.press(.toggle, at: 10)
        awaiting.trigger(.systemInterrupted, at: 11)
        awaiting.send(.microphoneAccess(.granted))
        awaiting.expectSettled()
    }

    @Test func theEngineStillPreparing() {
        var machine = Machine(engine: .preparing)
        let id = machine.recordHold(at: 10)
        #expect(PillContent(machine.state) == .waiting(preparingModel: true))
        machine.send(.engine(.ready))
        machine.transcript(id, "After preparation")
        machine.insertion(id, .inserted, text: "After preparation")
        machine.expectSettled()
    }

    @Test func theEngineFailingDuringARecording() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        machine.started(id1)
        machine.send(.engine(.failed(.loadFailed)))
        machine.trigger(.togglePressed, at: 14)
        machine.ended(id1, audio: 4)
        machine.send(.transcript(id1, .failure(.engineUnavailable(.loadFailed))))
        #expect(machine.log.records.map(\.outcome) == [.transcriptionFailed])
        #expect(machine.press(.hold, at: 20) == nil, "and the next press shows the engine notice")
        #expect(machine.state.notice?.message == .engineFailed(.loadFailed))
        machine.expectSettled()
    }

    @Test func theLimitWithTheKeyStillDown() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.fire(.captureLimit(id1))
        machine.ended(id1, audio: SessionTiming.captureLimit)
        machine.release(at: 10 + SessionTiming.captureLimit + 3)
        machine.transcript(id1, "A very long invented speech")
        machine.insertion(id1, .inserted, text: "A very long invented speech")
        #expect(machine.log.startedDictation == id1)
        machine.expectSettled()
    }

    @Test func pasteAgainInEverySituation() {
        var machine = Machine()
        machine.dictate("Invented", at: 1)
        #expect(machine.trigger(.pasteAgainPressed, at: 5).acted, "idle")
        #expect(!machine.trigger(.pasteAgainPressed, at: 5.01).acted, "twice quickly")
        machine.send(.reinsertion(ReplayID(1), .inserted))
        let id = machine.recordHold(at: 6)
        machine.transcript(id, "Second")
        #expect(!machine.trigger(.pasteAgainPressed, at: 9).acted, "during an insertion")
        machine.insertion(id, .inserted, text: "Second")
        machine.press(.hold, at: 10)
        machine.started(id3)
        #expect(!machine.trigger(.pasteAgainPressed, at: 11).acted, "during a recording")
        machine.release(at: 12)
        machine.ended(id3)
        machine.transcript(id3, "Third")
        machine.insertion(id3, .inserted, text: "Third")
        #expect(machine.trigger(.pasteAgainPressed, at: 20).effects
                == [.reinsert(ReplayID(2), text: "Third", restoreClipboard: true)])
        machine.send(.reinsertion(ReplayID(2), .inserted))
        machine.expectSettled()
    }

    @Test func onlyPressEnterPostedOrNot() {
        for outcome in [InsertionOutcome.inserted, .failed(.commandNotPosted)] {
            var machine = Machine()
            machine.dictate("Earlier", at: 1)
            let id = machine.recordHold(at: 10)
            machine.transcript(id, "press enter")
            machine.insertion(id, outcome, text: "", heard: "press enter", pressEnter: true)
            #expect(machine.state.lastText == "Earlier")
            machine.expectSettled()
        }
    }

    @Test func aMacroWithEmptyText() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "my empty macro")
        machine.insertion(id, .nothingToInsert, text: "", heard: "my empty macro")
        #expect(machine.log.records.isEmpty && machine.state.notice == nil && machine.state.lastText == nil)
        machine.expectSettled()
    }

    @Test func leftOnClipboardOrAFailureFollowedByAQueuedItem() {
        for outcome in [InsertionOutcome.leftOnClipboard(.modifiersStillDown), .failed(.eventPostFailed)] {
            var machine = Machine()
            let first = machine.recordHold(at: 10)
            let second = machine.recordHold(at: 13)
            machine.transcript(first, "First")
            machine.transcript(second, "Second")
            #expect(machine.insertion(first, outcome, text: "First").inserts.map(\.id) == [second])
            #expect(machine.state.notice?.kind == .error)
            #expect(PillContent(machine.state) == machine.state.notice.map(PillContent.notice), "shown over the wait")
            machine.insertion(second, .inserted, text: "Second")
            #expect(machine.state.lastText == "Second")
            machine.expectSettled()
        }
    }

    @Test func duplicateCompletionEventsAreDropped() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 12)
        machine.ended(id1)
        #expect(machine.ended(id1).isEmpty)
        machine.transcript(id1, "Invented")
        #expect(machine.transcript(id1, "Invented").isEmpty)
        machine.insertion(id1, .inserted, text: "Invented")
        #expect(machine.insertion(id1, .inserted, text: "Invented").isEmpty)
        #expect(machine.send(.capture(id1, .ended(CaptureSummary(duration: 2)))).isEmpty)
        #expect(machine.log.completions.count == 1)
        machine.expectSettled()
    }
}

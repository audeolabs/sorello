import DictationCore
import Foundation
import Testing

// Rules 6 to 12 of ARCHITECTURE.md, section 3. Rule 5 is in DoubleTapTests.swift.

@Suite("Rule 6: Cancel")
struct RuleCancelTests {
    @Test(arguments: [TriggerEvent.cancelPressed, .pillCancelClicked])
    func cancellingWhileStartingDiscardsThatDictation(_ cancel: TriggerEvent) {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        let outcome = machine.trigger(cancel, at: 10.5)
        #expect(outcome.acted)
        #expect(outcome.effects == [.cancelTimer(.captureStart(id1)), .discard(id1),
                                    .complete(DictationCompletion(id: id1, ending: .discarded))])
        machine.expectSettled()
    }

    @Test func cancellingWhileRecordingLeavesThePipelineAlone() {
        var machine = Machine()
        let older = machine.recordHold(at: 10)
        let live = machine.press(.hold, at: 13)
        if let live { machine.started(live) }
        let outcome = machine.trigger(.cancelPressed, at: 14)
        #expect(outcome.acted)
        #expect(outcome.effects.discarded == [id2])
        #expect(live == id2)
        #expect(machine.state.capture == .idle)
        #expect(machine.state.stages == [Stage(older, .transcribing(audio: 2))])
    }

    @Test func cancellingOtherwiseDiscardsEveryItemNotBeingInserted() {
        var machine = Machine()
        let inserting = machine.recordHold(at: 10)
        let ready = machine.recordHold(at: 13)
        machine.transcript(inserting, "First invented line")
        machine.transcript(ready, "Second invented line")
        let draining = machine.press(.hold, at: 16)
        if let draining {
            machine.started(draining)
            machine.release(at: 17)
        }
        #expect(machine.state.stages == [Stage(ready, .ready(SpeechResult(text: "Second invented line"))),
                                         Stage(id3, .draining(drainTimerArmed: true))])
        let outcome = machine.trigger(.cancelPressed, at: 17.5)
        #expect(outcome.acted)
        #expect(outcome.effects == [
            .discard(ready), .complete(DictationCompletion(id: ready, ending: .discarded,
                                                           speech: SpeechResult(text: "Second invented line"))),
            .cancelTimer(.captureDrain(id3)), .discard(id3), .complete(DictationCompletion(id: id3, ending: .discarded)),
        ])
        #expect(machine.state.pipeline.isEmpty)
        #expect(machine.state.insertingID == inserting)
    }

    @Test func cancellingATranscribingItemDiscardsIt() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        #expect(machine.trigger(.cancelPressed, at: 13).effects.discarded == [id])
        machine.expectSettled()
    }

    @Test func aPasteIsNeverRetracted() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "Invented")
        let outcome = machine.trigger(.cancelPressed, at: 13)
        #expect(!outcome.acted, "Escape is not consumed")
        #expect(outcome.effects.isEmpty)
        #expect(machine.state.insertingID == id)
    }

    @Test func aReplayIsLeftAlone() {
        var machine = Machine()
        machine.dictate("Invented", at: 10)
        machine.trigger(.pasteAgainPressed, at: 20)
        let outcome = machine.trigger(.cancelPressed, at: 20.1)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        #expect(machine.state.output == .replaying(ReplayID(1)))
    }

    @Test func escapeWithNothingToCancelIsNotConsumed() {
        var machine = Machine()
        #expect(!machine.trigger(.cancelPressed, at: 10).acted)
        machine.dictate("Invented", at: 11)
        #expect(!machine.trigger(.cancelPressed, at: 20).acted, "a notice or a last text is not cancelled")
    }
}

@Suite("Rule 7: Other triggers")
struct RuleOtherTriggerTests {
    @Test func aTogglePressDuringAHoldRecordingIsIgnored() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        let outcome = machine.trigger(.togglePressed, at: 11)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        #expect(machine.state.capture.live?.mode == .hold)
    }

    @Test func aHoldPressDuringAToggleRecordingIsIgnored() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        machine.started(id1)
        let outcome = machine.trigger(.holdPressed, at: 11)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        #expect(machine.trigger(.holdReleased(.keyUp), at: 11.5).effects.isEmpty, "its release is ignored too")
        #expect(machine.state.capture.live?.mode == .toggle)
    }

    @Test func anAbandonedHoldIsDiscardedWithoutANotice() {
        for startedFirst in [false, true] {
            var machine = Machine()
            machine.press(.hold, at: 10)
            if startedFirst { machine.started(id1) }
            let outcome = machine.trigger(.holdAbandoned, at: 10.2)
            #expect(outcome.acted)
            #expect(outcome.effects.discarded == [id1])
            #expect(outcome.effects.shownNotices == 0)
            #expect(machine.state.notice == nil)
            machine.expectSettled()
        }
    }

    @Test func anAbandonedHoldDuringAToggleRecordingDoesNothing() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        let outcome = machine.trigger(.holdAbandoned, at: 10.2)
        #expect(!outcome.acted && outcome.effects.isEmpty)
    }

    @Test func aReleaseWithNoHoldIsIgnored() {
        var machine = Machine()
        let outcome = machine.trigger(.holdReleased(.keyUp), at: 10)
        #expect(!outcome.acted && outcome.effects.isEmpty)
    }

    @Test func aKeyStillDownAfterTheLimitStartsNothingUntilPressedAgain() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.fire(.captureLimit(id1))
        #expect(machine.release(at: 10 + SessionTiming.captureLimit + 5).isEmpty)
        #expect(machine.state.capture == .idle)
        #expect(machine.press(.hold, at: 2000) == id2)
    }

    @Test func aSystemInterruptionDiscardsADictationStillStarting() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        let outcome = machine.trigger(.systemInterrupted, at: 10.5)
        #expect(outcome.acted)
        #expect(outcome.effects.discarded == [id1])
        #expect(machine.state.notice == nil)
        machine.expectSettled()
    }

    @Test(arguments: [TriggerMode.hold, .toggle])
    func aSystemInterruptionStopsARecordingInEitherMode(_ mode: TriggerMode) {
        var machine = Machine()
        machine.press(mode, at: 10)
        machine.started(id1)
        #expect(machine.trigger(.systemInterrupted, at: 12).effects.contains(.stopCapture(id1)))
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))])
    }

    @Test func aSystemInterruptionLeavesThePipelineAndResumesNothing() {
        var machine = Machine()
        let older = machine.recordHold(at: 10)
        let outcome = machine.trigger(.systemInterrupted, at: 13)
        #expect(!outcome.acted && outcome.effects.isEmpty)
        #expect(machine.state.stages == [Stage(older, .transcribing(audio: 2))])
    }
}

@Suite("Rule 8: Order")
struct RuleOrderTests {
    @Test func anEmptyTranscriptAfterASecondShowsNothingHeard() {
        var machine = Machine()
        let id = machine.recordHold(at: 10, for: SessionTiming.nothingHeardAfter)
        let effects = machine.transcript(id, "")
        #expect(machine.state.notice?.message == .nothingHeard)
        #expect(effects.completions == [DictationCompletion(id: id, ending: .nothingHeard,
                                                            speech: SpeechResult(text: ""))])
        #expect(effects.records.isEmpty, "nothing heard is not recorded")
        machine.expectSettled()
    }

    @Test func anEmptyTranscriptUnderASecondIsSilent() {
        var machine = Machine()
        let id = machine.recordHold(at: 10, for: 0.9)
        #expect(machine.transcript(id, "").shownNotices == 0)
        machine.expectSettled()
    }

    @Test func whitespaceIsAnEmptyTranscript() {
        var machine = Machine()
        let id = machine.recordHold(at: 10, for: 3)
        machine.transcript(id, "  \n")
        #expect(machine.state.notice?.message == .nothingHeard)
        machine.expectSettled()
    }

    @Test func aTranscriptKeepsItsCorrectionID() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        let effects = machine.send(.transcript(id, .success(SpeechResult(text: "Invented", correctionID: 7))))
        #expect(effects.inserts.first?.speech == SpeechResult(text: "Invented", correctionID: 7))
    }

    @Test func aReadyHeadIsInsertedAtOnce() {
        var machine = Machine(settings: SessionSettings(restoreClipboard: false))
        let id = machine.recordHold(at: 10)
        let effects = machine.transcript(id, "Invented line")
        #expect(effects == [.insert(InsertionRequest(id: id, speech: SpeechResult(text: "Invented line"),
                                                     style: .plain, restoreClipboard: false))])
        #expect(machine.state.insertingID == id)
        #expect(machine.state.pipeline.isEmpty)
    }

    @Test func laterItemsWaitEvenIfTheyWereReadyFirst() {
        var machine = Machine()
        let first = machine.recordHold(at: 10)
        let second = machine.recordHold(at: 13)
        #expect(machine.transcript(second, "Second").inserts.isEmpty)
        #expect(machine.state.stages == [Stage(first, .transcribing(audio: 2)),
                                         Stage(second, .ready(SpeechResult(text: "Second")))])
        #expect(machine.transcript(first, "First").inserts.map(\.id) == [first])
        #expect(machine.insertion(first, .inserted, text: "First").inserts.map(\.id) == [second])
    }

    @Test func aReadyHeadWaitsForAReplay() {
        var machine = Machine()
        machine.dictate("Earlier", at: 1)
        machine.trigger(.pasteAgainPressed, at: 5)
        let id = machine.recordHold(at: 6)
        #expect(machine.transcript(id, "Later").inserts.isEmpty)
        #expect(machine.send(.reinsertion(ReplayID(1), .inserted)).inserts.map(\.id) == [id])
    }

    @Test func aDuplicateTranscriptIsDropped() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "Invented")
        #expect(machine.transcript(id, "Invented").isEmpty)
        machine.insertion(id, .inserted, text: "Invented")
        #expect(machine.transcript(id, "Invented").isEmpty)
    }

    @Test func aTranscriptWhileDrainingIsDropped() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        machine.release(at: 12)
        #expect(machine.transcript(id1, "Too early").isEmpty)
        #expect(machine.state.stages == [Stage(id1, .draining(drainTimerArmed: true))])
    }
}

@Suite("Rule 9: Insertion")
struct RuleInsertionTests {
    private func inserting(_ text: String = "Invented line") -> Machine {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        machine.transcript(id, text)
        return machine
    }

    @Test func insertedRecordsRemembersAndCompletes() {
        var machine = inserting()
        let processed = ProcessedDictation(heard: "invented line", text: "Invented line.")
        let effects = machine.send(.insertion(id1, InsertionReport(outcome: .inserted, processed: processed)))
        #expect(effects == [
            .record(RunLogEntry(dictation: id1, heard: "invented line", text: "Invented line.", outcome: .inserted)),
            .complete(DictationCompletion(id: id1, ending: .insertion(.inserted),
                                          speech: SpeechResult(text: "Invented line"), processed: processed)),
        ])
        #expect(machine.state.lastText == "Invented line.")
        #expect(machine.state.notice == nil)
        machine.expectSettled()
    }

    @Test func leftOnClipboardRecordsRemembersAndTellsTheUserToPaste() {
        var machine = inserting()
        let effects = machine.insertion(id1, .leftOnClipboard(.accessibilityMissing), text: "Invented line")
        #expect(effects.records.map(\.outcome) == [.leftOnClipboard])
        #expect(machine.state.lastText == "Invented line")
        #expect(machine.state.notice?.message == .leftOnClipboard(.accessibilityMissing))
        #expect(machine.state.notice?.kind == .error)
    }

    @Test func aDictationThatOnlyPressedReturnLeavesTheRememberedText() {
        var machine = Machine()
        machine.dictate("Earlier", at: 1)
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "press enter")
        let effects = machine.insertion(id, .inserted, text: "", heard: "press enter", pressEnter: true)
        #expect(effects.records == [RunLogEntry(dictation: id, heard: "press enter", text: "", outcome: .inserted)])
        #expect(machine.state.lastText == "Earlier")
    }

    @Test func nothingToInsertDoesNothingMore() {
        var machine = Machine()
        machine.dictate("Earlier", at: 1)
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "empty macro")
        let effects = machine.insertion(id, .nothingToInsert, text: "", heard: "empty macro")
        #expect(effects.records.isEmpty)
        #expect(effects.shownNotices == 0)
        #expect(effects.completions.map(\.ending) == [.insertion(.nothingToInsert)])
        #expect(machine.state.lastText == "Earlier")
        machine.expectSettled()
    }

    @Test func aFailureRecordsAndShowsAnError() {
        var machine = inserting()
        let effects = machine.insertion(id1, .failed(.eventPostFailed), text: "Invented line")
        #expect(effects.records == [RunLogEntry(dictation: id1, heard: "Invented line", text: "Invented line",
                                                outcome: .insertionFailed)])
        #expect(machine.state.notice?.message == .insertionFailed(.eventPostFailed))
        #expect(machine.state.lastText == nil)
    }

    @Test func aReturnThatCouldNotBePostedSaysSo() {
        var machine = inserting("press enter")
        machine.insertion(id1, .failed(.commandNotPosted), text: "", heard: "press enter", pressEnter: true)
        #expect(machine.state.notice?.message == .insertionFailed(.commandNotPosted))
        #expect(machine.state.lastText == nil)
    }

    @Test func aTransactionThatEndedBeforeComposingRecordsWhatWasHeard() {
        var machine = inserting()
        let effects = machine.send(.insertion(id1, InsertionReport(outcome: .failed(.cancelled), processed: nil)))
        #expect(effects.records == [RunLogEntry(dictation: id1, heard: "Invented line", text: "",
                                                outcome: .insertionFailed)])
        #expect(effects.completions.first?.processed == nil)
    }

    @Test func freeingTheOutputInsertsTheNextReadyItem() {
        var machine = Machine()
        let first = machine.recordHold(at: 10)
        let second = machine.recordHold(at: 13)
        machine.transcript(first, "First")
        machine.transcript(second, "Second")
        #expect(machine.insertion(first, .failed(.pasteboardUnavailable), text: "First").inserts.map(\.id)
                == [second])
    }

    @Test func nothingIsPostedForADictationTwice() {
        var machine = inserting()
        machine.insertion(id1, .inserted, text: "Invented line")
        #expect(machine.insertion(id1, .inserted, text: "Invented line").isEmpty, "a duplicate report is dropped")
        #expect(machine.log.inserts.count == 1)
    }

    @Test func anInsertionReportForAnItemNotBeingInsertedIsDropped() {
        var machine = Machine()
        let first = machine.recordHold(at: 10)
        let second = machine.recordHold(at: 13)
        machine.transcript(second, "Second")
        #expect(machine.insertion(second, .inserted, text: "Second").isEmpty)
        #expect(machine.insertion(first, .inserted, text: "First").isEmpty)
        #expect(machine.state.dictationCount == 2)
    }
}

@Suite("Rule 10: Failures")
struct RuleFailureTests {
    @Test func theStartTimerDiscardsAndShowsTheMicrophoneNotice() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        let effects = machine.fire(.captureStart(id1))
        #expect(effects.discarded == [id1])
        #expect(!effects.contains(.cancelTimer(.captureStart(id1))), "a fired timer is not cancelled")
        #expect(machine.state.notice?.message == .microphoneUnavailable)
        machine.expectSettled()
    }

    @Test func aFailureWhileStartingDiscardsAndShowsTheMicrophoneNotice() {
        var machine = Machine()
        machine.press(.toggle, at: 10)
        let effects = machine.send(.capture(id1, .failed(.deviceUnavailable)))
        #expect(effects.contains(.cancelTimer(.captureStart(id1))))
        #expect(effects.discarded == [id1])
        #expect(machine.state.notice?.message == .microphoneUnavailable)
        machine.expectSettled()
    }

    @Test func theStartTimerAndTheFailureInEitherOrderEndTheDictationOnce() {
        var timerFirst = Machine()
        timerFirst.press(.hold, at: 10)
        timerFirst.fire(.captureStart(id1))
        #expect(timerFirst.send(.capture(id1, .failed(.startTimedOut))).isEmpty)
        timerFirst.expectSettled()

        var failureFirst = Machine()
        failureFirst.press(.hold, at: 10)
        failureFirst.send(.capture(id1, .failed(.startTimedOut)))
        #expect(failureFirst.fire(.captureStart(id1)).isEmpty)
        failureFirst.expectSettled()
        #expect(timerFirst.state == failureFirst.state)
    }

    @Test func aFailedTranscriptIsRecordedWithItsAudioForARetry() {
        var machine = Machine()
        let id = machine.recordHold(at: 10)
        let effects = machine.send(.transcript(id, .failure(.failed)))
        #expect(effects.records == [RunLogEntry(dictation: id, heard: "", text: "", outcome: .transcriptionFailed)])
        #expect(effects.completions == [DictationCompletion(id: id, ending: .transcriptionFailed(.failed))])
        #expect(machine.state.notice?.message == .transcriptionFailed)
        machine.expectSettled()
    }

    @Test func anEngineFailureDoesNotInterruptARecording() {
        var machine = Machine()
        machine.press(.hold, at: 10)
        machine.started(id1)
        #expect(machine.send(.engine(.failed(.loadFailed))).isEmpty)
        #expect(machine.state.capture.live?.id == id1)
        machine.release(at: 15)
        machine.ended(id1, audio: 5)
        machine.send(.transcript(id1, .failure(.engineUnavailable(.loadFailed))))
        #expect(machine.state.notice?.message == .transcriptionFailed)
        machine.expectSettled()
    }
}

@Suite("Rule 11: Paste Again")
struct RulePasteAgainTests {
    @Test func pasteAgainWhenIdleReplaysTheLastText() {
        var machine = Machine(settings: SessionSettings(restoreClipboard: false))
        machine.dictate("Invented line", at: 1)
        let outcome = machine.trigger(.pasteAgainPressed, at: 10)
        #expect(outcome.acted)
        #expect(outcome.effects == [.reinsert(ReplayID(1), text: "Invented line", restoreClipboard: false)])
        #expect(machine.state.output == .replaying(ReplayID(1)))
        let done = machine.send(.reinsertion(ReplayID(1), .inserted))
        #expect(done.isEmpty, "a replay is not recorded and completes no dictation")
        #expect(machine.state.output == .free)
    }

    @Test func pasteAgainWithNothingRememberedDoesNothing() {
        var machine = Machine()
        let outcome = machine.trigger(.pasteAgainPressed, at: 10)
        #expect(!outcome.acted && outcome.effects.isEmpty)
    }

    @Test func pasteAgainTwiceQuicklyReplaysOnce() {
        var machine = Machine()
        machine.dictate("Invented", at: 1)
        machine.trigger(.pasteAgainPressed, at: 10)
        #expect(machine.trigger(.pasteAgainPressed, at: 10.05).effects.isEmpty)
        machine.send(.reinsertion(ReplayID(1), .inserted))
        #expect(machine.trigger(.pasteAgainPressed, at: 11).effects
                == [.reinsert(ReplayID(2), text: "Invented", restoreClipboard: true)])
    }

    @Test func pasteAgainDuringAnInsertionOrARecordingDoesNothing() {
        var machine = Machine()
        machine.dictate("Earlier", at: 1)
        let id = machine.recordHold(at: 10)
        machine.transcript(id, "Later")
        #expect(machine.trigger(.pasteAgainPressed, at: 13).effects.isEmpty, "inserting")
        machine.insertion(id, .inserted, text: "Later")
        machine.press(.toggle, at: 20)
        #expect(machine.trigger(.pasteAgainPressed, at: 20.5).effects.isEmpty, "starting")
        machine.started(id2)
        #expect(machine.trigger(.pasteAgainPressed, at: 21).effects.isEmpty, "recording")
        machine.trigger(.togglePressed, at: 22)
        #expect(machine.trigger(.pasteAgainPressed, at: 22.5).effects.isEmpty, "draining")
    }

    @Test func aReplayThatPastedOnlyFreesTheOutput() {
        var machine = Machine()
        machine.dictate("Invented", at: 1)
        machine.trigger(.pasteAgainPressed, at: 10)
        #expect(machine.send(.reinsertion(ReplayID(1), .inserted)).isEmpty)
        #expect(machine.state.output == .free)
        #expect(machine.send(.reinsertion(ReplayID(1), .inserted)).isEmpty, "a stale report is dropped")
    }

    @Test func aReplayThatDidNotReachTheCursorSaysSo() {
        var machine = Machine()
        machine.dictate("Invented", at: 1)
        machine.trigger(.pasteAgainPressed, at: 10)
        let left = machine.send(.reinsertion(ReplayID(1), .leftOnClipboard(.modifiersStillDown)))
        #expect(left.shownNotices == 1)
        #expect(machine.state.notice?.message == .leftOnClipboard(.modifiersStillDown))
        #expect(machine.state.output == .free)
        #expect(left.records.isEmpty && left.completions.isEmpty, "a replay is never recorded")

        machine.trigger(.pasteAgainPressed, at: 20)
        let failed = machine.send(.reinsertion(ReplayID(2), .failed(.eventPostFailed)))
        #expect(failed.shownNotices == 1)
        #expect(machine.state.notice?.message == .insertionFailed(.eventPostFailed))
        #expect(machine.state.output == .free)
        #expect(failed.records.isEmpty && failed.completions.isEmpty)
    }

    @Test func clearingTheRunLogForgetsTheText() {
        var machine = Machine()
        machine.dictate("Invented", at: 1)
        machine.send(.forgetLast)
        #expect(machine.state.lastText == nil)
        #expect(machine.trigger(.pasteAgainPressed, at: 10).effects.isEmpty)
    }
}

@Suite("Rule 12: Notices")
struct RuleNoticeTests {
    @Test func informationLastsAShortTimeAndErrorsLonger() {
        var machine = Machine()
        let quiet = machine.recordHold(at: 10, for: 2)
        let info = machine.transcript(quiet, "")
        #expect(info.contains(.setTimer(.notice(NoticeID(1)), after: SessionTiming.informationNotice)))
        machine.press(.hold, at: 20)
        let error = machine.fire(.captureStart(id2))
        #expect(error.contains(.setTimer(.notice(NoticeID(2)), after: SessionTiming.errorNotice)))
        #expect(SessionTiming.informationNotice == 1.4 && SessionTiming.errorNotice == 4)
    }

    @Test func aNoticeExpiresByItsOwnTimer() {
        var machine = Machine()
        let quiet = machine.recordHold(at: 10, for: 2)
        machine.transcript(quiet, "")
        #expect(machine.fire(.notice(NoticeID(1))).isEmpty)
        #expect(machine.state.notice == nil)
    }

    @Test func aReplacedNoticeTimerCannotDismissItsSuccessor() {
        var machine = Machine(microphone: .denied)
        machine.press(.hold, at: 10)
        let replaced = machine.trigger(.holdPressed, at: 11).effects
        #expect(replaced.contains(.cancelTimer(.notice(NoticeID(1)))))
        #expect(machine.fire(.notice(NoticeID(1))).isEmpty)
        #expect(machine.state.notice?.id == NoticeID(2))
    }
}

extension SessionState {
    var insertingID: DictationID? {
        if case .inserting(let item) = output { return item.id }
        return nil
    }
}

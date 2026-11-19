import Foundation

/// `KeyboardDictationMachine` (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Phases, Transcription, Binding).
enum KeyboardDictationMachineTests {
    static var tests: [TestCase] {
        [
            ("aBoundDictationIsInsertedOnce", testABoundDictationIsInsertedOnce),
            ("phasesShowAsTheHostsModes", testPhasesShowAsTheHostsModes),
            ("aSecondTapWhileRunningStartsNothing", testASecondTapWhileRunningStartsNothing),
            ("stopInStartingCancels", testStopInStartingCancels),
            ("stopInRecordingSealsOnce", testStopInRecordingSealsOnce),
            ("stopAndCancelActOnlyOnTheShownAttempt", testStopAndCancelActOnlyOnTheShownAttempt),
            ("cancelEndsEveryPhase", testCancelEndsEveryPhase),
            ("hidingEndsEveryPhaseAndDropsTheText", testHidingEndsEveryPhaseAndDropsTheText),
            ("theHostTakingTheMicrophoneEndsIt", testTheHostTakingTheMicrophoneEndsIt),
            ("startupTimeoutCountsOnlyInStarting", testStartupTimeoutCountsOnlyInStarting),
            ("startupTimeoutGoesToTheHostOnlyWhileBound", testStartupTimeoutGoesToTheHostOnlyWhileBound),
            ("captureFailuresDependOnThePhase", testCaptureFailuresDependOnThePhase),
            ("anAudioGapLosesCaptureOnlyWhileItIsOpen", testAnAudioGapLosesCaptureOnlyWhileItIsOpen),
            ("theMaximumDurationStopsAsIfTapped", testTheMaximumDurationStopsAsIfTapped),
            ("noResultWithinTheFinishTimeoutFails", testNoResultWithinTheFinishTimeoutFails),
            ("modelAndTranscriptionFailuresShowTheHostsWords", testModelAndTranscriptionFailuresShowTheHostsWords),
            ("lateEventsOfAnEndedAttemptDoNothing", testLateEventsOfAnEndedAttemptDoNothing),
            ("stepsComeOnlyWhileTheAttemptRuns", testStepsComeOnlyWhileTheAttemptRuns),
            ("aFocusChangeEndsTheBindingForGood", testAFocusChangeEndsTheBindingForGood),
            ("aTextWaitingBoundIsOfferedAfterAFocusChange", testATextWaitingBoundIsOfferedAfterAFocusChange),
            ("noFieldIdentityMeansOffered", testNoFieldIdentityMeansOffered),
            ("theChipTakesOnlyWhatItShowedOnce", testTheChipTakesOnlyWhatItShowedOnce),
            ("textIsDroppedAtResultTTL", testTextIsDroppedAtResultTTL),
            ("anEmptyTranscriptIsNoSpeech", testAnEmptyTranscriptIsNoSpeech),
            ("eachTextWaitsOnItsOwn", testEachTextWaitsOnItsOwn),
            ("anExpiredTextIsNeverTaken", testAnExpiredTextIsNeverTaken),
            ("callbacksAfterADeadlineFindItEnded", testCallbacksAfterADeadlineFindItEnded),
            ("deadlinesFollowThePhase", testDeadlinesFollowThePhase),
            ("recordWritesBetweenStepsAreThrottled", testRecordWritesBetweenStepsAreThrottled),
        ]
    }

    private typealias Machine = KeyboardDictationMachine
    private static let wall = Date(timeIntervalSince1970: 1_800_000_000)

    private static func result(_ attempt: UUID, _ text: String = "Synthetic sample sentence", pressEnter: Bool = false)
    -> DictationResult {
        DictationResult(requestID: attempt, hostRunID: Fixture.hostRunID, text: text, pressEnter: pressEnter,
                        createdAt: wall)
    }

    /// A machine with one attempt tapped at 0 in `document`, and, with `recording`, its first audio at 1.
    private static func started(in document: UUID? = Fixture.documentA, recording: Bool = false) -> (Machine, UUID) {
        var machine = Machine()
        let id = UUID()
        _ = machine.handle(.tap(attempt: id, documentID: document), at: 0)
        if recording { _ = machine.handle(.audio(attempt: id, level: 0.5), at: 1) }
        return (machine, id)
    }

    /// Recorded from 1 to 3 and stopped at 3.
    private static func transcribing(in document: UUID? = Fixture.documentA) -> (Machine, UUID) {
        var (machine, id) = started(in: document, recording: true)
        _ = machine.handle(.audio(attempt: id, level: 0.4), at: 2)
        _ = machine.handle(.stop(attempt: id), at: 3)
        return (machine, id)
    }

    /// One machine in each running phase with a moment inside its deadlines: starting, recording (audio at 1) and
    /// transcribing (stopped at 3).
    private static func everyPhase() -> [(Machine, UUID, Machine.Instant)] {
        let (starting, startingID) = started()
        let (recording, recordingID) = started(recording: true)
        let (stopped, stoppedID) = transcribing()
        return [(starting, startingID, 2), (recording, recordingID, 2), (stopped, stoppedID, 3.5)]
    }

    private static func testABoundDictationIsInsertedOnce() {
        var machine = Machine()
        let id = UUID()
        TestSupport.expectEqual(machine.handle(.tap(attempt: id, documentID: Fixture.documentA), at: 0),
                                [.step(.tapped, id), .openCapture(id), .step(.captureRequested, id), .loadModel(id)])
        TestSupport.expectEqual(machine.phase, .starting)
        TestSupport.expect(machine.isCaptureOpen, "capture is closed while starting")
        TestSupport.expectEqual(machine.handle(.modelLoading(attempt: id), at: 0.01), [.step(.modelLoading, id)])
        TestSupport.expectEqual(machine.handle(.audio(attempt: id, level: 0.3), at: 0.4), [.step(.firstAudio, id)])
        TestSupport.expectEqual(machine.handle(.audio(attempt: id, level: 0.6), at: 0.5), [])
        TestSupport.expectEqual(machine.phase, .recording)
        TestSupport.expectEqual(machine.handle(.modelReady(attempt: id), at: 1.5), [.step(.modelReady, id)])
        TestSupport.expectEqual(machine.handle(.audio(attempt: id, level: 0.4), at: 2), [])
        TestSupport.expectEqual(machine.handle(.stop(attempt: id), at: 3), [.seal(id), .step(.stopped, id)])
        TestSupport.expectEqual(machine.phase, .transcribing)
        TestSupport.expect(!machine.isCaptureOpen, "capture is open while transcribing")
        TestSupport.expectEqual(machine.handle(.firstChunkDecoded(attempt: id), at: 3.1), [.step(.firstChunkDecoded, id)])
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: id, result: result(id)), at: 3.4),
                                [.step(.transcribed, id), .outcome(.text, id)])
        TestSupport.expect(!machine.isRunning, "the attempt still runs after its text")
        TestSupport.expectEqual(machine.offeredText, nil)
        TestSupport.expectEqual(machine.takeBoundText(at: 10), result(id))
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), nil)
        TestSupport.expectEqual(machine.mode(at: 3.5, wallNow: wall), nil)
    }

    private static func testPhasesShowAsTheHostsModes() {
        var (machine, id) = started()
        TestSupport.expectEqual(machine.mode(at: 0.5, wallNow: wall), .starting)
        _ = machine.handle(.audio(attempt: id, level: 0.2), at: 1)
        _ = machine.handle(.audio(attempt: id, level: 0.7), at: 2.5)
        TestSupport.expectEqual(machine.mode(at: 4, wallNow: wall), .recording(level: 0.7, startedAt: wall - 3))
        _ = machine.handle(.audio(attempt: id, level: 5), at: 4.1)
        TestSupport.expectEqual(machine.mode(at: 4.1, wallNow: wall), .recording(level: 1, startedAt: wall - 3.1))
        _ = machine.handle(.audio(attempt: id, level: .nan), at: 4.2)
        TestSupport.expectEqual(machine.mode(at: 4.2, wallNow: wall), .recording(level: 0, startedAt: wall - 3.2))
        _ = machine.handle(.stop(attempt: id), at: 5)
        TestSupport.expectEqual(machine.mode(at: 5, wallNow: wall), .transcribing)
        TestSupport.expectEqual(Machine().mode(at: 0, wallNow: wall), nil)
    }

    private static func testASecondTapWhileRunningStartsNothing() {
        var (machine, id) = started(recording: true)
        TestSupport.expectEqual(machine.handle(.tap(attempt: UUID(), documentID: Fixture.documentA), at: 2), [])
        TestSupport.expectEqual(machine.runningAttemptID, id)
    }

    private static func testStopInStartingCancels() {
        var (machine, id) = started()
        TestSupport.expectEqual(machine.handle(.stop(attempt: id), at: 1), [.tearDown(id), .outcome(.cancelled, id)])
        TestSupport.expect(!machine.isRunning, "stop in starting left it running")
        TestSupport.expectEqual(machine.mode(at: 1, wallNow: wall), nil)
    }

    private static func testStopInRecordingSealsOnce() {
        var (machine, id) = transcribing()
        // Mic taps in transcribing do nothing; audio after the seal is not kept.
        TestSupport.expectEqual(machine.handle(.stop(attempt: id), at: 4), [])
        TestSupport.expectEqual(machine.handle(.audio(attempt: id, level: 1), at: 4.1), [])
        TestSupport.expectEqual(machine.handle(.captureFailed(attempt: id), at: 4.2), [])
        TestSupport.expectEqual(machine.phase, .transcribing)
    }

    private static func testStopAndCancelActOnlyOnTheShownAttempt() {
        var (machine, id) = started(recording: true)
        let other = UUID()
        TestSupport.expectEqual(machine.handle(.stop(attempt: other), at: 2), [])
        TestSupport.expectEqual(machine.handle(.cancel(attempt: other), at: 2), [])
        TestSupport.expectEqual(machine.phase, .recording)
        TestSupport.expectEqual(machine.handle(.cancel(attempt: id), at: 2.5), [.tearDown(id), .outcome(.cancelled, id)])
        // Once ended, they are inert.
        TestSupport.expectEqual(machine.handle(.stop(attempt: id), at: 3.1), [])
        TestSupport.expectEqual(machine.handle(.cancel(attempt: id), at: 3.1), [])
    }

    private static func testCancelEndsEveryPhase() {
        for (machine, id, at) in everyPhase() {
            var machine = machine
            TestSupport.expectEqual(machine.handle(.cancel(attempt: id), at: at), [.tearDown(id), .outcome(.cancelled, id)])
            TestSupport.expectEqual(machine.mode(at: at, wallNow: wall), nil)
            TestSupport.expect(!machine.lastEndedCaptureUnavailable, "a cancel stuck as captureUnavailable")
        }
    }

    private static func testHidingEndsEveryPhaseAndDropsTheText() {
        for (machine, id, at) in everyPhase() {
            var machine = machine
            TestSupport.expectEqual(machine.handle(.hide, at: at), [.tearDown(id), .outcome(.keyboardDismissed, id)])
            TestSupport.expectEqual(machine.mode(at: at, wallNow: wall), nil)
        }
        var (machine, id) = transcribing(in: nil)
        _ = machine.handle(.transcribed(attempt: id, result: result(id)), at: 4)
        TestSupport.expectEqual(machine.offeredText, result(id))
        TestSupport.expectEqual(machine.handle(.hide, at: 5), [.step(.dropped, id)])
        TestSupport.expectEqual(machine.offeredText, nil)
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), nil)
        TestSupport.expectEqual(machine.handle(.hide, at: 6), [])
        // A shown failure goes with the keyboard too.
        var (failed, failedID) = started(recording: true)
        _ = failed.handle(.modelFailed(attempt: failedID), at: 2)
        _ = failed.handle(.hide, at: 2.5)
        TestSupport.expectEqual(failed.mode(at: 2.6, wallNow: wall), nil)
    }

    private static func testTheHostTakingTheMicrophoneEndsIt() {
        for (machine, id, at) in everyPhase() {
            var machine = machine
            TestSupport.expectEqual(machine.handle(.hostOwnsMicrophone, at: at), [.tearDown(id), .outcome(.hostTookOver, id)])
            TestSupport.expectEqual(machine.mode(at: at, wallNow: wall), nil)
        }
        var idle = Machine()
        TestSupport.expectEqual(idle.handle(.hostOwnsMicrophone, at: 0), [])
    }

    private static func testStartupTimeoutCountsOnlyInStarting() {
        var (machine, id) = started()
        TestSupport.expectEqual(machine.handle(.tick, at: KeyboardDictationTiming.startupTimeout - 0.01), [])
        TestSupport.expectEqual(machine.handle(.tick, at: KeyboardDictationTiming.startupTimeout),
                                [.tearDown(id), .outcome(.startupTimeout, id), .handToHost(documentID: Fixture.documentA)])
        TestSupport.expectEqual(machine.mode(at: 5, wallNow: wall), nil)
        // Recording, it no longer counts.
        var (recording, _) = started(recording: true)
        for second in stride(from: 2.0, through: 8, by: 1) {
            _ = recording.handle(.audio(attempt: recording.runningAttemptID!, level: 0.2), at: second)
            TestSupport.expectEqual(recording.handle(.tick, at: second + 0.5), [])
        }
        TestSupport.expectEqual(recording.phase, .recording)
    }

    /// Nothing was heard: the tap goes on as a host tap only while the attempt's field binding holds.
    private static func testStartupTimeoutGoesToTheHostOnlyWhileBound() {
        var (unbound, unboundID) = started(in: nil)
        TestSupport.expectEqual(unbound.handle(.tick, at: 5), [.tearDown(unboundID), .outcome(.startupTimeout, unboundID)])
        var (moved, movedID) = started()
        _ = moved.handle(.focus(documentID: Fixture.documentB), at: 1)
        _ = moved.handle(.focus(documentID: Fixture.documentA), at: 2)
        TestSupport.expectEqual(moved.handle(.tick, at: 5), [.tearDown(movedID), .outcome(.startupTimeout, movedID)])
        var (same, sameID) = started()
        _ = same.handle(.focus(documentID: Fixture.documentA), at: 1)
        TestSupport.expectEqual(same.handle(.captureFailed(attempt: sameID), at: 2),
                                [.tearDown(sameID), .outcome(.captureUnavailable, sameID), .handToHost(documentID: Fixture.documentA)])
    }

    private static func testCaptureFailuresDependOnThePhase() {
        var (starting, startingID) = started()
        TestSupport.expectEqual(starting.handle(.captureFailed(attempt: startingID), at: 1),
                                [.tearDown(startingID), .outcome(.captureUnavailable, startingID), .handToHost(documentID: Fixture.documentA)])
        TestSupport.expect(starting.lastEndedCaptureUnavailable, "captureUnavailable is not remembered")
        TestSupport.expectEqual(starting.mode(at: 1, wallNow: wall), nil)
        var (recording, recordingID) = started(recording: true)
        TestSupport.expectEqual(recording.handle(.captureFailed(attempt: recordingID), at: 2),
                                [.tearDown(recordingID), .outcome(.captureLost, recordingID)])
        TestSupport.expect(!recording.lastEndedCaptureUnavailable, "captureLost stuck as captureUnavailable")
        TestSupport.expectEqual(recording.mode(at: 2, wallNow: wall), .error(.interrupted))
        TestSupport.expectEqual(recording.mode(at: 2 + KeyboardPresenter.errorDisplayDuration - 0.01, wallNow: wall),
                                .error(.interrupted))
        TestSupport.expectEqual(recording.mode(at: 2 + KeyboardPresenter.errorDisplayDuration, wallNow: wall), nil)
        // A new tap clears the shown failure.
        _ = recording.handle(.tap(attempt: UUID(), documentID: nil), at: 3)
        TestSupport.expectEqual(recording.mode(at: 3, wallNow: wall), .starting)
    }

    private static func testAnAudioGapLosesCaptureOnlyWhileItIsOpen() {
        var (machine, id) = started(recording: true)
        _ = machine.handle(.audio(attempt: id, level: 0.2), at: 2)
        TestSupport.expectEqual(machine.handle(.tick, at: 2 + KeyboardDictationTiming.audioGap - 0.01), [])
        TestSupport.expectEqual(machine.handle(.tick, at: 2 + KeyboardDictationTiming.audioGap),
                                [.tearDown(id), .outcome(.captureLost, id)])
        // The sealing stop cancels the gap.
        var (sealed, sealedID) = transcribing()
        TestSupport.expectEqual(sealed.handle(.tick, at: 30), [])
        TestSupport.expectEqual(sealed.runningAttemptID, sealedID)
    }

    private static func testTheMaximumDurationStopsAsIfTapped() {
        var (machine, id) = started(recording: true)
        var second = 1.0
        while second < 1 + DictationProtocol.maxDictationDuration - 1 {
            second += 1
            _ = machine.handle(.audio(attempt: id, level: 0.2), at: second)
            TestSupport.expectEqual(machine.handle(.tick, at: second + 0.5), [])
        }
        _ = machine.handle(.audio(attempt: id, level: 0.2), at: 1 + DictationProtocol.maxDictationDuration - 0.1)
        TestSupport.expectEqual(machine.handle(.tick, at: 1 + DictationProtocol.maxDictationDuration),
                                [.seal(id), .step(.stopped, id)])
        TestSupport.expectEqual(machine.phase, .transcribing)
    }

    private static func testNoResultWithinTheFinishTimeoutFails() {
        var (machine, id) = transcribing()
        TestSupport.expectEqual(machine.handle(.tick, at: 3 + KeyboardDictationTiming.finishTimeout - 0.01), [])
        TestSupport.expectEqual(machine.handle(.tick, at: 3 + KeyboardDictationTiming.finishTimeout),
                                [.tearDown(id), .outcome(.transcriptionFailed, id)])
        TestSupport.expectEqual(machine.mode(at: 124, wallNow: wall), .error(.transcriptionFailed))
        // The text that comes after it inserts nothing.
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: id, result: result(id)), at: 124), [])
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
    }

    private static func testModelAndTranscriptionFailuresShowTheHostsWords() {
        for (machine, id, at) in everyPhase() {
            var machine = machine
            TestSupport.expectEqual(machine.handle(.modelFailed(attempt: id), at: at), [.tearDown(id), .outcome(.modelFailed, id)])
            TestSupport.expectEqual(machine.mode(at: at, wallNow: wall), .error(.modelFailed))
        }
        var (machine, id) = transcribing()
        TestSupport.expectEqual(machine.handle(.transcriptionFailed(attempt: id), at: 4),
                                [.tearDown(id), .outcome(.transcriptionFailed, id)])
        TestSupport.expectEqual(machine.mode(at: 4, wallNow: wall), .error(.transcriptionFailed))
        // A transcription failure before the stop is not one.
        var (recording, recordingID) = started(recording: true)
        TestSupport.expectEqual(recording.handle(.transcriptionFailed(attempt: recordingID), at: 2), [])
    }

    /// Every end marks the attempt ended first: nothing it started has any effect afterwards, and a new attempt is not
    /// touched by the old one's events.
    private static func testLateEventsOfAnEndedAttemptDoNothing() {
        let ends: [(UUID) -> KeyboardDictationMachine.Event] = [
            { .cancel(attempt: $0) }, { _ in .hide }, { _ in .hostOwnsMicrophone }, { .modelFailed(attempt: $0) },
        ]
        for makeEnd in ends {
            var (machine, old) = transcribing()
            _ = machine.handle(makeEnd(old), at: 4)
            let late: [KeyboardDictationMachine.Event] = [
                .audio(attempt: old, level: 1), .captureFailed(attempt: old), .modelLoading(attempt: old),
                .modelReady(attempt: old), .modelFailed(attempt: old), .firstChunkDecoded(attempt: old),
                .transcribed(attempt: old, result: result(old)), .transcriptionFailed(attempt: old), .stop(attempt: old),
                .cancel(attempt: old),
            ]
            for event in late {
                TestSupport.expectEqual(machine.handle(event, at: 5), [])
            }
            TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
            TestSupport.expectEqual(machine.offeredText, nil)
            // A new attempt.
            let new = UUID()
            _ = machine.handle(.tap(attempt: new, documentID: Fixture.documentA), at: 6)
            for event in late {
                TestSupport.expectEqual(machine.handle(event, at: 6.5), [])
            }
            TestSupport.expectEqual(machine.runningAttemptID, new)
            TestSupport.expectEqual(machine.phase, .starting)
            // A late timer of the old attempt does nothing: only the new one's deadlines count.
            TestSupport.expectEqual(machine.handle(.tick, at: 6 + KeyboardDictationTiming.startupTimeout - 0.1), [])
        }
    }

    private static func testStepsComeOnlyWhileTheAttemptRuns() {
        var machine = Machine()
        let id = UUID()
        for event in [KeyboardDictationMachine.Event.modelLoading(attempt: id), .modelReady(attempt: id),
                      .firstChunkDecoded(attempt: id), .audio(attempt: id, level: 1), .stop(attempt: id)] {
            TestSupport.expectEqual(machine.handle(event, at: 0), [])
        }
    }

    /// The binding is the tap's field, and a focus change seen at any time ends it for good: A, then B, then A again.
    private static func testAFocusChangeEndsTheBindingForGood() {
        var (machine, id) = started(recording: true)
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentA), at: 1.5), [])
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentB), at: 2), [])
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentA), at: 2.5), [])
        _ = machine.handle(.stop(attempt: id), at: 2.9)
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: id, result: result(id)), at: 4),
                                [.step(.transcribed, id), .outcome(.text, id), .step(.offered, id)])
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(machine.offeredText, result(id))
        // A nil identity (a field connecting) ends it too.
        var (connecting, connectingID) = transcribing()
        _ = connecting.handle(.focus(documentID: nil), at: 3.5)
        _ = connecting.handle(.focus(documentID: Fixture.documentA), at: 3.6)
        _ = connecting.handle(.transcribed(attempt: connectingID, result: result(connectingID)), at: 4)
        TestSupport.expectEqual(connecting.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(connecting.offeredText, result(connectingID))
    }

    private static func testATextWaitingBoundIsOfferedAfterAFocusChange() {
        var (machine, id) = transcribing()
        _ = machine.handle(.transcribed(attempt: id, result: result(id)), at: 4)
        // The editing side was busy; meanwhile the focus moved.
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentA), at: 4.5), [])
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentB), at: 5), [.step(.offered, id)])
        TestSupport.expectEqual(machine.handle(.focus(documentID: Fixture.documentA), at: 5.5), [])
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), result(id))
    }

    private static func testNoFieldIdentityMeansOffered() {
        var (machine, id) = transcribing(in: nil)
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: id, result: result(id)), at: 4),
                                [.step(.transcribed, id), .outcome(.text, id), .step(.offered, id)])
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(machine.offeredText, result(id))
    }

    private static func testTheChipTakesOnlyWhatItShowedOnce() {
        var (machine, id) = transcribing(in: nil)
        _ = machine.handle(.transcribed(attempt: id, result: result(id)), at: 4)
        TestSupport.expectEqual(machine.takeOfferedText(UUID(), at: 10), nil)
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), result(id))
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), nil)
        // A bound one is not the chip's.
        var (bound, boundID) = transcribing()
        _ = bound.handle(.transcribed(attempt: boundID, result: result(boundID)), at: 4)
        TestSupport.expectEqual(bound.takeOfferedText(boundID, at: 10), nil)
    }

    private static func testTextIsDroppedAtResultTTL() {
        var (machine, id) = transcribing(in: nil)
        _ = machine.handle(.transcribed(attempt: id, result: result(id)), at: 4)
        TestSupport.expectEqual(machine.handle(.tick, at: 4 + DictationProtocol.resultTTL - 0.01), [])
        TestSupport.expectEqual(machine.offeredText, result(id))
        TestSupport.expectEqual(machine.handle(.tick, at: 4 + DictationProtocol.resultTTL), [.step(.dropped, id)])
        TestSupport.expectEqual(machine.takeOfferedText(id, at: 10), nil)
        var (bound, boundID) = transcribing()
        _ = bound.handle(.transcribed(attempt: boundID, result: result(boundID)), at: 4)
        TestSupport.expectEqual(bound.handle(.tick, at: 4 + DictationProtocol.resultTTL), [.step(.dropped, boundID)])
        TestSupport.expectEqual(bound.takeBoundText(at: 10), nil)
    }

    private static func testAnEmptyTranscriptIsNoSpeech() {
        var (machine, id) = transcribing()
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: id, result: result(id, "")), at: 4),
                                [.step(.transcribed, id), .outcome(.noSpeech, id), .noSpeech])
        TestSupport.expectEqual(machine.takeBoundText(at: 10), nil)
        TestSupport.expectEqual(machine.nextDeadline, nil)
        // Only "press enter" still presses Enter: not empty.
        var (enter, enterID) = transcribing()
        TestSupport.expectEqual(enter.handle(.transcribed(attempt: enterID, result: result(enterID, "", pressEnter: true)), at: 4),
                                [.step(.transcribed, enterID), .outcome(.text, enterID)])
        TestSupport.expectEqual(enter.takeBoundText(at: 10), result(enterID, "", pressEnter: true))
    }

    /// Each text waits on its own until it is taken, `resultTTL` after it was made, or the keyboard hides: a second
    /// one does not drop the first. The chip offers the newest unbound; insertion takes the oldest bound.
    private static func testEachTextWaitsOnItsOwn() {
        var (machine, first) = transcribing(in: nil)
        _ = machine.handle(.transcribed(attempt: first, result: result(first)), at: 4)
        let second = UUID()
        _ = machine.handle(.tap(attempt: second, documentID: nil), at: 5)
        _ = machine.handle(.audio(attempt: second, level: 0.3), at: 5.5)
        _ = machine.handle(.stop(attempt: second), at: 6)
        TestSupport.expectEqual(machine.handle(.transcribed(attempt: second, result: result(second)), at: 7),
                                [.step(.transcribed, second), .outcome(.text, second), .step(.offered, second)])
        TestSupport.expectEqual(machine.offeredText, result(second))
        TestSupport.expectEqual(machine.takeOfferedText(second, at: 8), result(second))
        // The first is still offered, by its own id, until its own TTL.
        TestSupport.expectEqual(machine.offeredText, result(first))
        TestSupport.expectEqual(machine.handle(.tick, at: 4 + DictationProtocol.resultTTL), [.step(.dropped, first)])
        TestSupport.expectEqual(machine.takeOfferedText(first, at: 4 + DictationProtocol.resultTTL), nil)
        // Bound texts are taken oldest first.
        var (bound, a) = transcribing()
        _ = bound.handle(.transcribed(attempt: a, result: result(a)), at: 4)
        let b = UUID()
        _ = bound.handle(.tap(attempt: b, documentID: Fixture.documentA), at: 5)
        _ = bound.handle(.audio(attempt: b, level: 0.3), at: 5.5)
        _ = bound.handle(.stop(attempt: b), at: 6)
        _ = bound.handle(.transcribed(attempt: b, result: result(b)), at: 7)
        TestSupport.expectEqual(bound.boundText, result(a))
        TestSupport.expectEqual(bound.takeBoundText(at: 8), result(a))
        TestSupport.expectEqual(bound.takeBoundText(at: 8), result(b))
        TestSupport.expectEqual(bound.takeBoundText(at: 8), nil)
    }

    /// A text past `resultTTL` is never taken, even before the tick that drops it.
    private static func testAnExpiredTextIsNeverTaken() {
        var (bound, boundID) = transcribing()
        _ = bound.handle(.transcribed(attempt: boundID, result: result(boundID)), at: 4)
        TestSupport.expectEqual(bound.takeBoundText(at: 4 + DictationProtocol.resultTTL), nil)
        var (offered, offeredID) = transcribing(in: nil)
        _ = offered.handle(.transcribed(attempt: offeredID, result: result(offeredID)), at: 4)
        TestSupport.expectEqual(offered.takeOfferedText(offeredID, at: 4 + DictationProtocol.resultTTL), nil)
        // A host-ownership check at delivery drops it by id.
        var (dropped, droppedID) = transcribing()
        _ = dropped.handle(.transcribed(attempt: droppedID, result: result(droppedID)), at: 4)
        TestSupport.expectEqual(dropped.dropText(UUID()), [])
        TestSupport.expectEqual(dropped.dropText(droppedID), [.step(.dropped, droppedID)])
        TestSupport.expectEqual(dropped.takeBoundText(at: 5), nil)
    }

    /// The clock is judged before every event: a callback that comes after a deadline, before its timer fired, finds
    /// the attempt ended.
    private static func testCallbacksAfterADeadlineFindItEnded() {
        // First audio after the startup timeout.
        var (starting, startingID) = started()
        TestSupport.expectEqual(starting.handle(.audio(attempt: startingID, level: 0.5), at: KeyboardDictationTiming.startupTimeout + 0.1),
                                [.tearDown(startingID), .outcome(.startupTimeout, startingID), .handToHost(documentID: Fixture.documentA)])
        TestSupport.expectEqual(starting.phase, .idle)
        // A chunk after the audio gap.
        var (recording, recordingID) = started(recording: true)
        TestSupport.expectEqual(recording.handle(.audio(attempt: recordingID, level: 0.5), at: 1 + KeyboardDictationTiming.audioGap + 0.1),
                                [.tearDown(recordingID), .outcome(.captureLost, recordingID)])
        // A text after the finish timeout.
        var (late, lateID) = transcribing()
        TestSupport.expectEqual(late.handle(.transcribed(attempt: lateID, result: result(lateID)), at: 3 + KeyboardDictationTiming.finishTimeout),
                                [.tearDown(lateID), .outcome(.transcriptionFailed, lateID)])
        TestSupport.expectEqual(late.takeBoundText(at: 124), nil)
        // A stop after the maximum duration's moment is the maximum duration's stop, once.
        var (long, longID) = started(recording: true)
        var second = 1.0
        while second < DictationProtocol.maxDictationDuration {
            second += 1
            _ = long.handle(.audio(attempt: longID, level: 0.2), at: second)
        }
        TestSupport.expectEqual(long.handle(.stop(attempt: longID), at: 1 + DictationProtocol.maxDictationDuration + 0.5),
                                [.seal(longID), .step(.stopped, longID)])
    }

    private static func testDeadlinesFollowThePhase() {
        var (machine, id) = started()
        TestSupport.expectEqual(machine.nextDeadline, KeyboardDictationTiming.startupTimeout)
        _ = machine.handle(.audio(attempt: id, level: 0.2), at: 1)
        TestSupport.expectEqual(machine.nextDeadline, 1 + KeyboardDictationTiming.audioGap)
        _ = machine.handle(.stop(attempt: id), at: 2)
        TestSupport.expectEqual(machine.nextDeadline, 2 + KeyboardDictationTiming.finishTimeout)
        _ = machine.handle(.modelFailed(attempt: id), at: 3)
        TestSupport.expectEqual(machine.nextDeadline, 3 + KeyboardPresenter.errorDisplayDuration)
        _ = machine.handle(.tick, at: 3 + KeyboardPresenter.errorDisplayDuration)
        TestSupport.expectEqual(machine.nextDeadline, nil)
    }

    private static func testRecordWritesBetweenStepsAreThrottled() {
        var schedule = KeyboardDictationRecordSchedule()
        TestSupport.expect(!schedule.isDue(at: 0), "a write is due with nothing changed")
        schedule.figuresChanged()
        TestSupport.expect(schedule.isDue(at: 0), "the first change is not written")
        schedule.figuresChanged()
        TestSupport.expect(!schedule.isDue(at: 0.5), "written twice within the interval")
        TestSupport.expect(schedule.isDue(at: KeyboardDictationTiming.recordInterval), "a change waits past the interval")
        TestSupport.expect(!schedule.isDue(at: 5), "a write is due with nothing changed since")
        // A step's write covers the change.
        schedule.figuresChanged()
        schedule.wrote(at: 5.5)
        TestSupport.expect(!schedule.isDue(at: 7), "a change a step wrote is written again")
        // A clock that went back writes at once.
        schedule.figuresChanged()
        TestSupport.expect(schedule.isDue(at: 2), "a backward clock holds the write")
    }
}

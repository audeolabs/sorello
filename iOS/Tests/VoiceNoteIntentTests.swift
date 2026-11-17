import Foundation

/// The voice note's intents on the host side (ARCHITECTURE.md, "Voice Note control"; "Live Activity", Buttons): what
/// the "Voice Note" control and the Live Activity's Note and Stop do, through the real core with its fakes, a real notes
/// directory and a fake ActivityKit backend, and the one sentence a start that needs the app fails with.
enum VoiceNoteIntentTests {
    static var tests: [TestCase] {
        [
            ("eachOutcomeHasOneStep", testEachOutcomeHasOneStep),
            ("eachRefusalSaysWhy", testEachRefusalSaysWhy),
            ("controlStartsAndStopsInTheBackground", isolated(testControlStartsAndStopsInTheBackground)),
            ("controlNeedsItsLiveActivity", isolated(testControlNeedsItsLiveActivity)),
            ("controlJoiningASessionNeedsItsLiveActivity", isolated(testControlJoiningASessionNeedsItsLiveActivity)),
            ("controlInFront", isolated(testControlInFront)),
            ("controlRefusals", isolated(testControlRefusals)),
            ("activityNoteAndStop", isolated(testActivityNoteAndStop)),
            ("recorderSaysWhetherAVaultExists", testRecorderSaysWhetherAVaultExists),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// The core with a vault (unless said otherwise), the session's activity over a fake backend, and the controller's
    /// way of letting the activity start during an intent.
    @MainActor
    private final class Rig {
        let notes = NoteFixture()
        let h: CoreHarness
        let backend = FakeActivityBackend()
        let driver: SessionActivityDriver

        init(vault: Bool = true, foreground: Bool = false) {
            if vault { try! notes.vault.makeVault() }
            h = CoreHarness(launch: false, notes: notes)
            driver = SessionActivityDriver(backend: backend)
            h.clock.isForeground = foreground
            h.core.launch()
        }

        func sync(mayStart: Bool = false) {
            driver.sync(h.core.activityInput(noteVault: notes.recorder.hasVault), mayStart: mayStart, now: h.clock.now)
            h.core.sessionActivityStartedAt = driver.startedAt
        }

        /// A press of the control, as iOS runs it: inside the intent, capture may start in the background.
        func toggle() -> VoiceNoteIntentStep? {
            h.clock.controlRunning = true
            defer { h.clock.controlRunning = false }
            var step: VoiceNoteIntentStep?
            Task { @MainActor in
                step = await VoiceNoteIntentFlow.toggleFromControl(h.core) {
                    self.sync(mayStart: true)
                    return await self.driver.settle()
                }
            }
            _ = TestSupport.waitUntil(timeout: 2) { step != nil }
            sync()
            return step
        }

        /// Lets the note that saves end.
        func finishSaving() {
            h.completeTail()
            let stream = h.noteStream
            _ = TestSupport.waitUntil(timeout: 2) { stream.finishCount == 1 }
            stream.complete(.success(""))
            _ = TestSupport.waitUntil(timeout: 2) { self.h.core.voiceNote == nil }
            sync()
        }

        func cleanup() { h.cleanup() }
    }

    // MARK: Steps and sentences

    private static func testEachOutcomeHasOneStep() {
        let step = VoiceNoteIntentFlow.step(for:)
        for done in [NoteStartOutcome.started, .startedInBackground, .stopped, .busy] {
            TestSupport.expectEqual(step(done), .done)
        }
        TestSupport.expectEqual(step(.needsApp(.noVault)), .needsApp(.noVault))
        TestSupport.expectEqual(step(.needsApp(.microphone)), .needsApp(.microphone))
        TestSupport.expectEqual(step(.needsApp(.locked)), .needsApp(.locked))
        TestSupport.expectEqual(step(.needsApp(.foreground)), .needsApp(.foreground))
        TestSupport.expectEqual(step(.needsApp(.liveActivity)), .needsApp(.liveActivity))
        TestSupport.expectEqual(step(.failed(.microphonePermissionDenied)), .needsApp(.microphone))
        for reason in [NoteEndReason.captureFailed, .interrupted, .sessionEnded] {
            TestSupport.expectEqual(step(.failed(reason)), .needsApp(.foreground))
        }
        TestSupport.expectEqual(step(.failed(.modelUnavailable)), .failed(.model))
        TestSupport.expectEqual(step(.failed(.modelFailed)), .failed(.model))
        TestSupport.expectEqual(step(.failed(.storageFailed)), .failed(.storage))
        TestSupport.expectEqual(step(.failed(.noteGone)), .failed(.storage))
        for reason in [NoteEndReason.transcriptionFailed, .backgroundTimeExpired] {
            TestSupport.expectEqual(step(.failed(reason)), .failed(.other))
        }
    }

    /// One sentence each, that says why: no vault yet, the microphone, the lock, the Live Activity, or open Sorello.
    private static func testEachRefusalSaysWhy() {
        TestSupport.expectEqual(VoiceNoteIntentStep.done.message, nil)
        let expected: [(VoiceNoteIntentStep, String)] = [
            (.needsApp(.noVault), "Open Sorello to set up notes first."),
            (.needsApp(.microphone), "Open Sorello to allow the microphone."),
            (.needsApp(.locked), "Unlock iPhone to start a note."),
            (.needsApp(.liveActivity), "Turn on Live Activities for Sorello, or open it to record."),
            (.needsApp(.foreground), "Open Sorello to start the note."),
            (.failed(.model), "The speech model could not load."),
            (.failed(.storage), "The note could not be saved."),
            (.failed(.other), "The note could not start."),
            (.unavailable, "Open Sorello to start a note."),
        ]
        for (step, sentence) in expected {
            TestSupport.expectEqual(step.message, sentence)
            let message = step.message ?? ""
            TestSupport.expect(message.hasSuffix(".") && message.filter { $0 == "." }.count == 1, "not one sentence: \(message)")
        }
    }

    // MARK: The control

    /// With the app in the background and no session, a press starts capture, the session's Live Activity shows the
    /// note, and the next press stops it; the session goes on.
    @MainActor
    private static func testControlStartsAndStopsInTheBackground() {
        let rig = Rig()
        defer { rig.cleanup() }
        TestSupport.expectEqual(rig.toggle(), .done)
        TestSupport.expectEqual(rig.h.core.session, .active)
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .recording)
        TestSupport.expectEqual(rig.backend.calls.first?.kind, .start)
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteRecording)
        rig.h.deliver()
        TestSupport.expectEqual(rig.toggle(), .done)
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .saving)
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteSaving)
        // A press while it saves changes nothing.
        TestSupport.expectEqual(rig.toggle(), .done)
        rig.finishSaving()
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteSaved)
        TestSupport.expectEqual(rig.h.core.session, .active)
    }

    /// A background start whose Live Activity does not show ends the session and the note at once, and says why.
    @MainActor
    private static func testControlNeedsItsLiveActivity() {
        for refusal in ["off", "refused", "refusedOnceQueued"] {
            let rig = Rig()
            defer { rig.cleanup() }
            switch refusal {
            case "off": rig.backend.enabled = false
            case "refused": rig.backend.refuses = true
            default: rig.backend.refusesOnceQueued = true
            }
            let step = rig.toggle()
            TestSupport.expectEqual(step, .needsApp(.liveActivity))
            TestSupport.expectEqual(rig.h.core.session, .inactive)
            TestSupport.expectEqual(rig.h.capture.isRunning, false)
            rig.finishSaving()
            TestSupport.expectEqual(rig.h.core.lastNote?.ending, .sessionEnded)
        }
    }

    /// Joining a session that already runs, from the background, the note needs the activity too: with Live
    /// Activities off it stops at once and says why, and the session, which was there before, goes on. Once the
    /// activity may show, as after the user removed it, the same press records.
    @MainActor
    private static func testControlJoiningASessionNeedsItsLiveActivity() {
        let rig = Rig(foreground: true)
        defer { rig.cleanup() }
        rig.backend.enabled = false
        rig.h.core.userStartSession()
        rig.h.deliver()
        TestSupport.expectEqual(rig.h.core.session, .active)
        rig.h.clock.isForeground = false
        rig.h.core.foregroundChanged()
        TestSupport.expectEqual(rig.toggle(), .needsApp(.liveActivity))
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .saving)   // stopped, as the user's stop
        rig.finishSaving()
        TestSupport.expectEqual(rig.h.core.lastNote?.ending, .stopped)
        TestSupport.expectEqual(rig.h.core.session, .active)
        TestSupport.expectEqual(rig.h.capture.isRunning, true)
        rig.backend.enabled = true
        TestSupport.expectEqual(rig.toggle(), .done)
        rig.h.deliver()
        rig.sync()
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .recording)
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteRecording)
    }

    /// In front, the note starts as the app's own Record does, and the activity starts during the intent even with the
    /// app only inactive (Control Center over it).
    @MainActor
    private static func testControlInFront() {
        let rig = Rig(foreground: true)
        defer { rig.cleanup() }
        TestSupport.expectEqual(rig.toggle(), .done)
        rig.h.deliver()
        rig.sync()
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .recording)
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteRecording)
        // A refusal in front leaves the note recording.
        let refusing = Rig(foreground: true)
        defer { refusing.cleanup() }
        refusing.backend.refuses = true
        TestSupport.expectEqual(refusing.toggle(), .done)
        TestSupport.expect(refusing.h.core.voiceNote != nil, "the note ended without its activity in front")
    }

    @MainActor
    private static func testControlRefusals() {
        let noVault = Rig(vault: false)
        defer { noVault.cleanup() }
        TestSupport.expectEqual(noVault.toggle(), .needsApp(.noVault))
        TestSupport.expectEqual(noVault.h.core.session, .inactive)
        TestSupport.expectEqual(noVault.backend.calls, [])

        let microphone = Rig()
        defer { microphone.cleanup() }
        microphone.h.capture.permission = .undetermined
        TestSupport.expectEqual(microphone.toggle(), .needsApp(.microphone))

        let locked = Rig()
        defer { locked.cleanup() }
        locked.h.core.deviceWillLock()
        locked.h.clock.now += HostSessionPolicy.lockWriteWindow - 1
        TestSupport.expectEqual(locked.toggle(), .needsApp(.locked))

        let model = Rig()
        defer { model.cleanup() }
        model.h.transcriber.modelState = .unavailable
        TestSupport.expectEqual(model.toggle(), .failed(.model))
        TestSupport.expectEqual(model.h.core.session, .inactive)
    }

    // MARK: The Live Activity's buttons

    /// Note starts a new note in the running session from the background; Stop stops it without anything else, the
    /// iPhone locked included, and never fails.
    @MainActor
    private static func testActivityNoteAndStop() {
        let rig = Rig(foreground: true)
        defer { rig.cleanup() }
        rig.h.core.userStartSession()
        rig.sync(mayStart: true)
        TestSupport.expectEqual(rig.backend.calls.last?.state, SessionActivityState(phase: .ready,
                                                                                  endsAt: rig.h.core.sessionExpiresAt,
                                                                                  offersNote: true))
        rig.h.clock.isForeground = false
        rig.h.core.foregroundChanged()
        TestSupport.expectEqual(VoiceNoteIntentFlow.startFromActivity(rig.h.core), .done)
        rig.sync()
        TestSupport.expectEqual(rig.backend.calls.last?.state?.phase, .noteRecording)
        let noteID = rig.h.core.voiceNoteID
        TestSupport.expect(noteID != nil, "no note")
        // A second Note while it records changes nothing.
        TestSupport.expectEqual(VoiceNoteIntentFlow.startFromActivity(rig.h.core), .done)
        TestSupport.expectEqual(rig.h.core.voiceNoteID, noteID)
        rig.h.deliver()
        rig.h.core.deviceWillLock()
        TestSupport.expectEqual(VoiceNoteIntentFlow.stopFromActivity(rig.h.core), .done)
        TestSupport.expectEqual(rig.h.core.voiceNote?.phase, .saving)
        rig.finishSaving()
        TestSupport.expectEqual(rig.h.core.lastNote?.ending, .stopped)
        TestSupport.expectEqual(VoiceNoteIntentFlow.stopFromActivity(rig.h.core), .done)
        // Locked, Note needs the unlock iOS has not proved yet.
        TestSupport.expectEqual(VoiceNoteIntentFlow.startFromActivity(rig.h.core), .needsApp(.locked))
    }

    private static func testRecorderSaysWhetherAVaultExists() {
        let notes = NoteFixture()
        TestSupport.expectEqual(notes.recorder.hasVault, false)
        try! notes.vault.makeVault()
        TestSupport.expectEqual(notes.recorder.hasVault, true)
        notes.vault.lock()
        TestSupport.expectEqual(notes.recorder.hasVault, true)
        try! notes.vault.eraseAll()
        TestSupport.expectEqual(notes.recorder.hasVault, false)
    }
}

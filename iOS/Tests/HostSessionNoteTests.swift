import Foundation

/// A voice note in `HostSessionCore` (ARCHITECTURE.md, "Voice notes"), driven through the real core with the fakes of
/// `HostSessionCoreTests` and a real notes directory (`NoteFixture`), so what was written is read back from the vault.
/// Test text is invented.
enum HostSessionNoteTests {
    static var tests: [TestCase] {
        [
            ("inAppStartPreparesThenRecords", isolated(testInAppStartPreparesThenRecords)),
            ("piecesAreWrittenAsTheyArrive", isolated(testPiecesAreWrittenAsTheyArrive)),
            ("aNoteHasNoDictationCap", isolated(testANoteHasNoDictationCap)),
            ("keyboardRecordsWaitForTheNote", isolated(testKeyboardRecordsWaitForTheNote)),
            ("keyboardStopNoteStopsOnlyAnEarlierNote", isolated(testKeyboardStopNoteStopsOnlyAnEarlierNote)),
            ("sessionEndSavesWhatArrived", isolated(testSessionEndSavesWhatArrived)),
            ("streamFailureKeepsWhatWasWritten", isolated(testStreamFailureKeepsWhatWasWritten)),
            ("aPieceThatCannotBeWrittenEndsTheNote", isolated(testAPieceThatCannotBeWrittenEndsTheNote)),
            ("lockDoesNotEndTheNote", isolated(testLockDoesNotEndTheNote)),
            ("captureRecoveryKeepsTheRunAndStream", isolated(testCaptureRecoveryKeepsTheRunAndStream)),
            ("idleExpiryWaitsForTheNote", isolated(testIdleExpiryWaitsForTheNote)),
            ("batteryCapStopsTheNote", isolated(testBatteryCapStopsTheNote)),
            ("powerCapFollowsTheActivity", isolated(testPowerCapFollowsTheActivity)),
            ("failedPreparationEndsTheNote", isolated(testFailedPreparationEndsTheNote)),
            ("withoutAVaultTheStartNeedsTheApp", isolated(testWithoutAVaultTheStartNeedsTheApp)),
            ("controlTogglesANoteInTheBackground", isolated(testControlTogglesANoteInTheBackground)),
            ("controlStartsThatNeedTheApp", isolated(testControlStartsThatNeedTheApp)),
            ("activityStartNeedsALiveSession", isolated(testActivityStartNeedsALiveSession)),
            ("aNoteSupersedesARecordingDictation", isolated(testANoteSupersedesARecordingDictation)),
            ("lateCompletionsOfAnEndedNoteAreIgnored", isolated(testLateCompletionsOfAnEndedNoteAreIgnored)),
            ("saveRunsInABackgroundTask", isolated(testSaveRunsInABackgroundTask)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let R = Fixture.requestID
    private static let S = Fixture.otherRequestID
    private static let grace = HostSessionPolicy.captureStallGrace + 0.001

    /// A harness over a notes directory with a vault, the model ready unless said otherwise.
    @MainActor
    private static func harness(vault: Bool = true, launch: Bool = true,
                                maxDuration: TimeInterval = DictationProtocol.maxDictationDuration) -> (CoreHarness, NoteFixture) {
        let notes = NoteFixture()
        if vault { try! notes.vault.makeVault() }
        return (CoreHarness(launch: launch, maxDuration: maxDuration, notes: notes), notes)
    }

    /// The pieces the note's one run holds on disk.
    private static func pieces(_ notes: NoteFixture, _ id: UUID?) -> [String] {
        guard let id, let note = try? notes.vault.note(id) else { return [] }
        return note.pendingRuns.flatMap(\.pieces)
    }

    @MainActor
    private static func waitFor(_ message: String, _ condition: @escaping () -> Bool) {
        TestSupport.expect(TestSupport.waitUntil(timeout: 2, condition), message)
    }

    /// Stops the note, delivers its tail, and finishes its stream with `last` as the last report.
    @MainActor
    private static func stopAndSave(_ h: CoreHarness, last: String = "") {
        let stream = h.noteStream
        TestSupport.expect(h.core.stopNote(), "nothing to stop")
        h.completeTail()
        waitFor("the stream never finished") { stream.finishCount == 1 }
        if !last.isEmpty { stream.report(settled: last, provisional: "") }
        stream.complete(.success(last))
        waitFor("the note never ended") { h.core.voiceNote == nil }
    }

    // MARK: Scenarios

    /// The app's Record with no session starts one; until the model is ready the note prepares and keeps no audio,
    /// then the capture feeds a stream with progress. No dictation is published.
    @MainActor
    private static func testInAppStartPreparesThenRecords() {
        let (h, _) = harness()
        defer { h.cleanup() }
        var changes: [NoteChange] = []
        h.core.onNoteChange = { changes.append($0) }
        h.transcriber.modelState = .notPrepared
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .started)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.transcriber.modelState, .preparing)
        TestSupport.expectEqual(h.status?.voiceNote, VoiceNoteStatus(phase: .preparing, startedAt: Fixture.now,
                                                                     endsAt: Fixture.now + 3600, onPower: false))
        TestSupport.expectEqual(h.status?.sessionExpiresAt, nil)
        TestSupport.expectEqual(h.status?.dictation, nil)
        let id = h.core.voiceNoteID!
        TestSupport.expectEqual(changes, [.started(noteID: id)])
        h.deliver()
        TestSupport.expect(h.transcriber.noteStreams.isEmpty, "a stream before the model is ready")
        TestSupport.expectEqual(h.buffer.recordingToken, nil)

        h.transcriber.modelState = .ready
        h.core.modelStateChanged()
        waitFor("the note never recorded") { h.status?.voiceNote?.phase == .recording }
        for _ in 0..<3 { h.deliver() }
        TestSupport.expectEqual(h.noteStream.samples.count, 4_800)
        TestSupport.expectEqual(h.status?.dictation, nil)
        TestSupport.expectEqual(h.status?.level, 0)
        TestSupport.expectEqual(h.store.resultRequestIDs(), [])
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .busy)
    }

    /// Each settled piece is written the moment it is reported and the provisional tail goes to the observer; a stop
    /// drains the tail, finishes the stream, writes the last piece and ends the run.
    @MainActor
    private static func testPiecesAreWrittenAsTheyArrive() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        var changes: [NoteChange] = []
        var tails: [String] = []
        h.core.onNoteChange = { changes.append($0) }
        h.core.onNoteProvisional = { _, tail in tails.append(tail) }
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .started)
        let id = h.core.voiceNoteID!
        h.deliver()
        h.noteStream.report(settled: "Invented first piece.", provisional: "and a tail")
        waitFor("the report was not read") { h.core.lastNote?.piecesTranscribed == 1 }
        TestSupport.expectEqual(pieces(notes, id), ["Invented first piece."])
        TestSupport.expectEqual(tails, ["and a tail"])
        h.noteStream.report(settled: "", provisional: "and a longer tail")
        waitFor("the second report was not read") { h.core.lastNote?.piecesTranscribed == 2 }
        TestSupport.expectEqual(pieces(notes, id), ["Invented first piece."])
        TestSupport.expectEqual(changes, [.started(noteID: id), .wrote(noteID: id)])

        let stream = h.noteStream
        TestSupport.expect(h.core.stopNote(), "nothing to stop")
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        TestSupport.expectEqual(h.status?.voiceNote?.endsAt, nil)
        h.deliver(count: 400)   // captured before the stop, still in flight
        h.completeTail()
        waitFor("the stream never finished") { stream.finishCount == 1 }
        TestSupport.expectEqual(stream.samples.count, 2_000)
        stream.report(settled: "Invented last piece.", provisional: "")
        stream.complete(.success("Invented first piece. Invented last piece."))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.status?.voiceNote, nil)
        TestSupport.expectEqual(h.core.lastNote, NoteMeasurement(piecesTranscribed: 3, piecesWhileLocked: 0,
                                                                 piecesInBackground: 0, ending: .stopped, hint: nil))
        TestSupport.expectEqual(changes, [.started(noteID: id), .wrote(noteID: id), .wrote(noteID: id),
                                          .ended(noteID: id, reason: .stopped)])
        TestSupport.expect(!stream.isCancelled, "a saved note's stream was cancelled")
        // The run ended, so the vault merges it.
        try! notes.vault.mergePendingRuns()
        TestSupport.expectEqual(try! notes.vault.note(id).text, "Invented first piece. Invented last piece.")
        TestSupport.expectEqual(h.core.stopNote(), false)
    }

    /// A note keeps no samples, so neither the buffer's cap nor `maxDictationDuration` applies to it.
    @MainActor
    private static func testANoteHasNoDictationCap() {
        let (h, _) = harness(maxDuration: 0.5)
        defer { h.cleanup() }
        h.clock.power = .connected
        _ = h.core.userStartNote(.newNote)
        for _ in 0..<10 { h.deliver() }
        TestSupport.expectEqual(h.noteStream.samples.count, 16_000)
        h.clock.now += DictationProtocol.maxDictationDuration + 60
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.deliver()
        TestSupport.expectEqual(h.noteStream.samples.count, 17_600)
    }

    /// A keyboard record is refused with `noteRecording` while a note prepares or records, and admitted once it is
    /// stopped, its tail drained first.
    @MainActor
    private static func testKeyboardRecordsWaitForTheNote() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        h.transcriber.modelState = .notPrepared
        _ = h.core.userStartNote(.newNote)
        h.writeIntent(.record, R)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, R)
        TestSupport.expectEqual(h.status?.dictation?.phase, .failed)
        TestSupport.expectEqual(h.status?.dictation?.error, .noteRecording)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .preparing)

        h.transcriber.modelState = .ready
        h.core.modelStateChanged()
        waitFor("the note never recorded") { h.status?.voiceNote?.phase == .recording }
        h.clock.now += 1
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, S)
        TestSupport.expectEqual(h.status?.dictation?.error, .noteRecording)
        h.deliver()
        TestSupport.expectEqual(h.noteStream.samples.count, 1_600)

        // Stopped, still waiting for its tail: the next record is admitted, and the note saves what arrived.
        let id = h.core.voiceNoteID
        TestSupport.expect(h.core.stopNote(), "nothing to stop")
        let next = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        h.writeIntent(.record, next)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.dictation?.requestID, next)
        TestSupport.expectEqual(h.status?.dictation?.phase, .starting)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        waitFor("the note's stream never finished") { h.noteStream.finishCount == 1 }
        h.deliver()
        TestSupport.expectEqual(h.noteStream.samples.count, 1_600)
        h.noteStream.report(settled: "Invented words.", provisional: "")
        h.noteStream.complete(.success("Invented words."))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(pieces(notes, id), ["Invented words."])
    }

    /// The keyboard's stop stops a note that started before it was issued, once; a stop issued earlier never stops a
    /// later note.
    @MainActor
    private static func testKeyboardStopNoteStopsOnlyAnEarlierNote() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.writeIntent(.stopNote, R)
        h.clock.now += 1
        _ = h.core.userStartNote(.newNote)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.clock.now += 1
        h.writeIntent(.stopNote, S)
        h.core.reconcile(.intentSignal)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        TestSupport.expectEqual(h.status?.dictation, nil)
    }

    /// The session ending under a recording note saves what arrived, with the session's reason; a preparing note just
    /// ends with it.
    @MainActor
    private static func testSessionEndSavesWhatArrived() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        _ = h.core.userStartNote(.newNote)
        let id = h.core.voiceNoteID
        h.deliver()
        h.noteStream.report(settled: "Invented before the call.", provisional: "")
        waitFor("the report was not read") { h.core.lastNote?.piecesTranscribed == 1 }
        h.core.captureInterrupted()
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success("Invented before the call."))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .interrupted)
        TestSupport.expectEqual(pieces(notes, id), ["Invented before the call."])

        _ = h.core.userStartNote(.newNote)
        h.core.userEndSession()
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .sessionEnded)

        h.transcriber.modelState = .notPrepared
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .preparing)
        h.core.captureMediaServicesReset()
        TestSupport.expectEqual(h.core.voiceNote, nil)
        TestSupport.expectEqual(h.core.lastNote?.ending, .captureFailed)
    }

    /// A stream that fails ends the note; what was written stays, the session goes on, and its idle countdown starts.
    /// In the background on iOS 27, Diagnostics gets the entitlement hint.
    @MainActor
    private static func testStreamFailureKeepsWhatWasWritten() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        h.transcriber.hint = .backgroundNeuralEngineNeedsEntitlement
        _ = h.core.userStartNote(.newNote)
        let id = h.core.voiceNoteID
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.noteStream.report(settled: "Invented and kept.", provisional: "")
        waitFor("the report was not read") { h.core.lastNote?.piecesTranscribed == 1 }
        let stream = h.noteStream
        h.clock.now += 5
        stream.endFeed()   // the engine failed: the feed ends while it is fed
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .transcriptionFailed)
        TestSupport.expectEqual(h.core.lastNote?.hint, .backgroundNeuralEngineNeedsEntitlement)
        TestSupport.expect(stream.isCancelled, "a failed note's stream is open")
        TestSupport.expectEqual(pieces(notes, id), ["Invented and kept."])
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.status?.sessionExpiresAt, h.clock.now + 300)
        h.deliver()
        TestSupport.expectEqual(stream.samples.count, 0)
    }

    /// A piece that cannot be written ends the note at once and cancels its stream.
    @MainActor
    private static func testAPieceThatCannotBeWrittenEndsTheNote() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        _ = h.core.userStartNote(.newNote)
        let id = h.core.voiceNoteID!
        // A file stands where the run's directory was, so its next segment cannot be written.
        for run in notes.runDirectories(of: id) {
            try! FileManager.default.removeItem(at: run)
            try! Data().write(to: run)
        }
        h.noteStream.report(settled: "Invented and lost.", provisional: "")
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .storageFailed)
        TestSupport.expect(h.noteStream.isCancelled, "the stream of a note that cannot be written is open")
    }

    /// A device lock does not end or pause a note. Only a report that arrives while iOS says protected data is
    /// unavailable counts as locked; one with the app in the background counts as background.
    @MainActor
    private static func testLockDoesNotEndTheNote() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        h.clock.power = .connected
        _ = h.core.userStartNote(.newNote)
        let id = h.core.voiceNoteID
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.core.deviceWillLock()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        // Inside the lock's first seconds protected data still reads available.
        h.noteStream.report(settled: "Invented in the grace.", provisional: "")
        waitFor("the report was not read") { h.core.lastNote?.piecesTranscribed == 1 }
        h.clock.protectedDataAvailable = false
        h.clock.now += 20 * 60
        for _ in 0..<3 { h.core.tick() }
        h.deliver()
        h.noteStream.report(settled: "Invented while locked.", provisional: "")
        waitFor("the report was not read") { h.core.lastNote?.piecesTranscribed == 2 }
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        TestSupport.expectEqual(h.core.lastNote?.piecesWhileLocked, 1)
        TestSupport.expectEqual(h.core.lastNote?.piecesInBackground, 2)
        TestSupport.expectEqual(h.noteStream.samples.count, 1_600)
        TestSupport.expectEqual(pieces(notes, id), ["Invented in the grace.", "Invented while locked."])
    }

    /// A capture recovery, as when the route changes, keeps the same run and stream: input goes on into it once it
    /// flows again. A conversion failure only asks for a recovery.
    @MainActor
    private static func testCaptureRecoveryKeepsTheRunAndStream() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.power = .connected
        _ = h.core.userStartNote(.newNote)
        let id = h.core.voiceNoteID
        h.deliver()
        let stream = h.noteStream
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.core.captureFailed(generation: h.capture.engineGeneration)
        h.clock.now += grace
        h.core.tick()
        TestSupport.expectEqual(h.capture.restartCount, 1)
        h.deliver()
        TestSupport.expectEqual(h.core.voiceNoteID, id)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        TestSupport.expect(h.noteStream === stream, "a recovery opened a new stream")
        TestSupport.expectEqual(stream.samples.count, 3_200)

        h.core.captureDelivered(.conversionFailed(generation: h.buffer.generation, engine: h.capture.engineGeneration))
        _ = TestSupport.waitUntil(timeout: 0.1) { false }   // the report hops to main
        h.clock.now += grace
        h.core.tick()
        TestSupport.expectEqual(h.capture.restartCount, 2)
        h.deliver()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        TestSupport.expectEqual(stream.samples.count, 4_800)
        TestSupport.expect(!stream.isCancelled, "a recovery cancelled the stream")
    }

    /// Idle expiry waits while a note records; the countdown starts when it stops.
    @MainActor
    private static func testIdleExpiryWaitsForTheNote() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.power = .connected
        h.core.userStartSession()
        h.clock.now += 60
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.status?.sessionExpiresAt, nil)
        for _ in 0..<4 {
            h.clock.now += 5 * 60
            h.deliver()
            h.core.tick()
        }
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        let stopped = h.clock.now
        stopAndSave(h)
        TestSupport.expectEqual(h.status?.sessionExpiresAt, stopped + 300)
        h.clock.now = stopped + 300.1
        h.core.tick()
        TestSupport.expectEqual(h.core.session, .inactive)
    }

    /// On battery the cap stops the note an hour after its start, or after the last unplug; `status.json` carries
    /// the deadline and the power flag.
    @MainActor
    private static func testBatteryCapStopsTheNote() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.power = .battery
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.status?.voiceNote?.endsAt, Fixture.now + 3600)
        TestSupport.expectEqual(h.status?.voiceNote?.onPower, false)
        h.clock.now += 1800
        h.clock.power = .connected
        h.deliver()
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.endsAt, nil)
        TestSupport.expectEqual(h.status?.voiceNote?.onPower, true)
        h.clock.now += 1800
        h.clock.power = .unknown   // unplugged: an unknown state is battery
        h.deliver()
        h.core.tick()
        let unplugged = h.clock.now
        TestSupport.expectEqual(h.status?.voiceNote?.endsAt, unplugged + 3600)
        h.clock.now = unplugged + 3600
        h.deliver()
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.clock.now += 0.2
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        h.completeTail()
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .reachedLimit)
    }

    /// With power connected the note ends when the session's Live Activity reaches its lifetime; a clock that jumps
    /// back ends it too.
    @MainActor
    private static func testPowerCapFollowsTheActivity() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.power = .connected
        h.core.sessionActivityStartedAt = Fixture.now - 7 * 3600
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.status?.voiceNote?.endsAt, nil)
        h.clock.now += 3599
        h.deliver()
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.clock.now += 1.2
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        stopAndSaveAfterTheCap(h)
        TestSupport.expectEqual(h.core.lastNote?.ending, .reachedLimit)

        h.core.sessionActivityStartedAt = nil
        _ = h.core.userStartNote(.newNote)
        h.clock.now -= 10
        h.core.tick()
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
    }

    @MainActor
    private static func stopAndSaveAfterTheCap(_ h: CoreHarness) {
        h.completeTail()
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }
    }

    /// A preparation that fails ends a preparing note; a missing or backing-off model fails the start at once, with
    /// no session started.
    @MainActor
    private static func testFailedPreparationEndsTheNote() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.transcriber.modelState = .notPrepared
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .preparing)
        h.transcriber.modelState = .failed
        h.core.modelStateChanged()
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .modelFailed)
        TestSupport.expectEqual(h.core.session, .active)
        h.core.userEndSession()

        h.transcriber.modelState = .unavailable
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .failed(.modelUnavailable))
        h.transcriber.modelState = .failed
        h.transcriber.backingOff = true
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .failed(.modelFailed))
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.status?.voiceNote, nil)
    }

    /// Without a vault every start needs the app, and nothing starts; without a notes directory it fails. A note that
    /// is gone fails its start.
    @MainActor
    private static func testWithoutAVaultTheStartNeedsTheApp() {
        let (h, notes) = harness(vault: false)
        defer { h.cleanup() }
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .needsApp(.noVault))
        h.clock.isForeground = false
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.controlNote(), .needsApp(.noVault))
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.capture.startCount, 0)
        TestSupport.expectEqual(h.status?.voiceNote, nil)

        try! notes.vault.makeVault()
        h.clock.isForeground = true
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.core.userStartNote(.note(UUID(), at: .end)), .failed(.noteGone))
        TestSupport.expectEqual(h.core.session, .inactive)

        let bare = CoreHarness()
        defer { bare.cleanup() }
        TestSupport.expectEqual(bare.core.userStartNote(.newNote), .failed(.storageFailed))
    }

    /// The control starts a session and a note in the background, as the session control starts a session; the next
    /// press stops the note; a press while it saves changes nothing. Its activity not showing ends both.
    @MainActor
    private static func testControlTogglesANoteInTheBackground() {
        let (h, _) = harness(launch: false)
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.core.launch()
        TestSupport.expectEqual(h.controlNote(), .startedInBackground)
        TestSupport.expectEqual(h.core.session, .active)
        TestSupport.expectEqual(h.capture.startCount, 1)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.deliver()
        TestSupport.expectEqual(h.controlNote(), .stopped)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .saving)
        TestSupport.expectEqual(h.controlNote(), .busy)
        h.completeTail()
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.session, .active)

        // With the session running, the note joins it.
        TestSupport.expectEqual(h.controlNote(), .started)
        TestSupport.expectEqual(h.capture.startCount, 1)
        h.core.userEndSession()
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }

        // Its Live Activity does not show: the session ends, and the note with it.
        TestSupport.expectEqual(h.controlNote(), .startedInBackground)
        TestSupport.expectEqual(h.core.noteNeedsForeground(), .needsApp(.liveActivity))
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.capture.isRunning, false)
        waitFor("the stream never finished") { h.noteStream.finishCount == 1 }
        h.noteStream.complete(.success(""))
        waitFor("the note never ended") { h.core.voiceNote == nil }
        TestSupport.expectEqual(h.core.lastNote?.ending, .sessionEnded)
    }

    /// Without microphone permission, with the latch set, or when iOS refuses capture, the control's start needs the
    /// app and leaves nothing running; it is not remembered for the app's arrival.
    @MainActor
    private static func testControlStartsThatNeedTheApp() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.capture.permission = .undetermined
        TestSupport.expectEqual(h.controlNote(), .needsApp(.microphone))
        TestSupport.expectEqual(h.core.session, .inactive)
        h.clock.isForeground = true
        h.core.appDidBecomeActive()
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.voiceNote, nil)

        h.capture.permission = .granted
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.core.deviceWillLock()
        h.clock.now += HostSessionPolicy.lockWriteWindow - 1
        TestSupport.expectEqual(h.controlNote(), .needsApp(.locked))
        h.clock.now += 30
        h.capture.failStart = true
        TestSupport.expectEqual(h.controlNote(), .needsApp(.foreground))
        TestSupport.expectEqual(h.core.isLocked, false)
        TestSupport.expectEqual(h.core.session, .inactive)
        TestSupport.expectEqual(h.status?.voiceNote, nil)
        TestSupport.expectEqual(h.core.lastNote?.ending, .captureFailed)
    }

    /// The Live Activity's start: in the background it needs a live session; the latch is lifted only as an
    /// authenticated intent proves the unlock.
    @MainActor
    private static func testActivityStartNeedsALiveSession() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.core.foregroundChanged()
        TestSupport.expectEqual(h.core.activityStartNote(.newNote), .needsApp(.foreground))
        h.clock.isForeground = true
        h.core.userStartSession()
        h.clock.isForeground = false
        h.core.foregroundChanged()
        h.core.deviceWillLock()
        h.clock.now += 5
        TestSupport.expectEqual(h.core.activityStartNote(.newNote), .needsApp(.locked))
        h.clock.now += HostSessionPolicy.lockWriteWindow
        TestSupport.expectEqual(h.core.activityStartNote(.newNote), .started)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        TestSupport.expectEqual(h.core.activityStartNote(.newNote), .busy)
        TestSupport.expectEqual(h.capture.startCount, 1)
    }

    /// A note starting while a dictation records takes the microphone: the dictation is cancelled as superseded.
    @MainActor
    private static func testANoteSupersedesARecordingDictation() {
        let (h, _) = harness()
        defer { h.cleanup() }
        h.record(R)
        TestSupport.expectEqual(h.core.userStartNote(.newNote), .started)
        TestSupport.expectEqual(h.status?.dictation?.phase, .cancelled)
        TestSupport.expectEqual(h.status?.dictation?.error, .superseded)
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        h.deliver()
        TestSupport.expectEqual(h.noteStream.samples.count, 1_600)
    }

    /// What an ended note's stream reports or returns later changes nothing for the next note.
    @MainActor
    private static func testLateCompletionsOfAnEndedNoteAreIgnored() {
        let (h, notes) = harness()
        defer { h.cleanup() }
        h.clock.isForeground = false
        h.core.foregroundChanged()
        _ = h.controlNote()
        let first = h.noteStream
        _ = h.core.stopNote()
        h.completeTail()
        waitFor("the stream never finished") { first.finishCount == 1 }
        h.background.expire(h.background.expirations.count - 1)
        TestSupport.expectEqual(h.core.voiceNote, nil)
        TestSupport.expectEqual(h.core.lastNote?.ending, .backgroundTimeExpired)
        TestSupport.expect(first.isCancelled, "an expired save kept its stream")

        _ = h.controlNote()
        let id = h.core.voiceNoteID
        first.report(settled: "Invented and late.", provisional: "")
        first.complete(.success("Invented and late."))
        _ = TestSupport.waitUntil(timeout: 0.2) { false }
        TestSupport.expectEqual(h.status?.voiceNote?.phase, .recording)
        TestSupport.expectEqual(h.core.lastNote?.piecesTranscribed, 0)
        TestSupport.expectEqual(pieces(notes, id), [])
    }

    /// The save runs inside a UIKit background task, which ends with it.
    @MainActor
    private static func testSaveRunsInABackgroundTask() {
        let (h, _) = harness()
        defer { h.cleanup() }
        _ = h.core.userStartNote(.newNote)
        TestSupport.expectEqual(h.background.begun, 0)
        stopAndSave(h)
        TestSupport.expectEqual(h.background.begun, 1)
        TestSupport.expectEqual(h.background.ended, 1)
    }
}

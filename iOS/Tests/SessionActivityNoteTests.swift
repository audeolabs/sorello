import Foundation

/// A voice note on the session's Live Activity (ARCHITECTURE.md, "Live Activity"): its own states for each host state,
/// the beat after a stop, the stale date a killed app leaves behind, and the one alert, against a fake ActivityKit
/// backend.
enum SessionActivityNoteTests {
    static var tests: [TestCase] {
        [
            ("aNoteHasItsOwnStates", testANoteHasItsOwnStates),
            ("aNoteIsNeverADictationOrIdle", testANoteIsNeverADictationOrIdle),
            ("theLastMinutesAndPower", testTheLastMinutesAndPower),
            ("noteOfferedOnlyWithAVault", testNoteOfferedOnlyWithAVault),
            ("noteStaleDates", testNoteStaleDates),
            ("aNoteIsSentAgainBeforeItGoesStale", isolated(testANoteIsSentAgainBeforeItGoesStale)),
            ("theLastMinutesAreOneUpdate", isolated(testTheLastMinutesAreOneUpdate)),
            ("aStopShowsTheSavedBeat", isolated(testAStopShowsTheSavedBeat)),
            ("onlyAStopOrTheCapShowsTheBeat", isolated(testOnlyAStopOrTheCapShowsTheBeat)),
            ("aRecordingEndsTheBeat", isolated(testARecordingEndsTheBeat)),
            ("theCapAlertsOnce", isolated(testTheCapAlertsOnce)),
            ("aNoteIsNeverHeldBehindAWait", isolated(testANoteIsNeverHeldBehindAWait)),
            ("noteMotionAndWords", testNoteMotionAndWords),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let now = Fixture.now
    private static let session = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!

    private static func note(_ phase: VoiceNoteStatus.Phase, startedAt: Date = now - 60, endsAt: Date? = now + 3540,
                             onPower: Bool = false) -> VoiceNoteStatus {
        VoiceNoteStatus(phase: phase, startedAt: startedAt, endsAt: onPower ? nil : endsAt, onPower: onPower)
    }

    private static func input(_ voiceNote: VoiceNoteStatus? = nil, dictation: DictationStatus? = nil,
                              ending: NoteEndReason? = nil, vault: Bool = true,
                              session state: HostStatus.Session = .active,
                              expiresAt: Date? = now + 300) -> SessionActivityInput {
        SessionActivityInput(sessionID: state == .inactive ? nil : session, session: state,
                             sessionExpiresAt: voiceNote == nil ? expiresAt : nil, dictation: dictation, model: .ready,
                             voiceNote: voiceNote, lastNoteEnding: voiceNote == nil ? ending : nil, noteVault: vault)
    }

    private static func state(_ input: SessionActivityInput, at time: Date = now) -> SessionActivityState? {
        SessionActivityPolicy.state(for: input, now: time)
    }

    // MARK: What it shows

    private static func testANoteHasItsOwnStates() {
        let startedAt = now - 60
        TestSupport.expectEqual(state(input(note(.preparing, startedAt: startedAt))),
                                SessionActivityState(phase: .notePreparing, endsAt: now + 3540))
        TestSupport.expectEqual(state(input(note(.recording, startedAt: startedAt))),
                                SessionActivityState(phase: .noteRecording, endsAt: now + 3540, since: startedAt))
        TestSupport.expectEqual(state(input(note(.saving))), SessionActivityState(phase: .noteSaving))
        TestSupport.expectEqual(state(input(note(.saving, onPower: true))), SessionActivityState(phase: .noteSaving, onPower: true))
        // No session, no activity, whatever the note says.
        TestSupport.expectEqual(state(input(note(.recording), session: .inactive)), nil)
        TestSupport.expectEqual(state(input(note(.preparing), session: .starting)), nil)
    }

    /// The microphone indicator is on for the whole session: only the activity says speech is being kept, so a note
    /// never reads as a dictation or as an idle session, whatever the dictation does beside it.
    private static func testANoteIsNeverADictationOrIdle() {
        for phase in [VoiceNoteStatus.Phase.preparing, .recording] {
            for dictation in [nil, Fixture.dictation(.transcribing), Fixture.dictation(.completed)] {
                let shown = state(input(note(phase), dictation: dictation))
                TestSupport.expect(shown?.isNoteInProgress == true, "\(phase) with \(String(describing: dictation?.phase)) shows \(String(describing: shown))")
            }
        }
        // A dictation started while the last note saves shows at once.
        TestSupport.expectEqual(state(input(note(.saving), dictation: Fixture.dictation(.recording, startedAt: now)))?.phase,
                                .recording)
        TestSupport.expectEqual(state(input(note(.saving), dictation: Fixture.dictation(.transcribing)))?.phase, .noteSaving)
    }

    /// On battery the time left counts down, in its last five minutes flagged for ember; with power connected there is
    /// no deadline and a bolt instead.
    private static func testTheLastMinutesAndPower() {
        let warning = SessionActivityPolicy.noteWarning
        TestSupport.expectEqual(warning, 5 * 60)
        TestSupport.expectEqual(state(input(note(.recording, endsAt: now + warning + 1)))?.lastMinutes, nil)
        TestSupport.expectEqual(state(input(note(.recording, endsAt: now + warning)))?.lastMinutes, true)
        TestSupport.expectEqual(state(input(note(.preparing, endsAt: now + 10)))?.lastMinutes, true)
        let onPower = state(input(note(.recording, onPower: true)))
        TestSupport.expectEqual(onPower?.onPower, true)
        TestSupport.expectEqual(onPower?.endsAt, nil)
        TestSupport.expectEqual(onPower?.lastMinutes, nil)
    }

    /// Note shows only in a ready session and only when a vault exists; never during a note or a dictation.
    private static func testNoteOfferedOnlyWithAVault() {
        TestSupport.expectEqual(state(input(vault: true)), SessionActivityState(phase: .ready, endsAt: now + 300, offersNote: true))
        TestSupport.expectEqual(state(input(vault: false)), SessionActivityState(phase: .ready, endsAt: now + 300))
        TestSupport.expectEqual(state(input(note(.recording), vault: true))?.offersNote, nil)
        TestSupport.expectEqual(state(input(dictation: Fixture.dictation(.recording), vault: true))?.offersNote, nil)
        TestSupport.expectEqual(state(input(dictation: Fixture.dictation(.transcribing), vault: true))?.offersNote, nil)
    }

    /// A note may record for hours with power connected: a killed app's activity must not read "Recording note" long
    /// after. Every note state goes stale a few minutes after it was sent, or just after the cap if that is sooner.
    private static func testNoteStaleDates() {
        let interval = SessionActivityPolicy.noteStaleInterval
        TestSupport.expect(interval >= 120 && interval <= 600, "a note's stale date is a few minutes away")
        TestSupport.expect(SessionActivityPolicy.noteStaleRefresh < interval, "the refresh comes after the state went stale")
        let onPower = SessionActivityState(phase: .noteRecording, since: now - 7200, onPower: true)
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: onPower, now: now), now + interval)
        let farCap = SessionActivityState(phase: .noteRecording, endsAt: now + 3000, since: now - 600)
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: farCap, now: now), now + interval)
        let nearCap = SessionActivityState(phase: .noteRecording, endsAt: now + 60, since: now - 3540)
        TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: nearCap, now: now), now + 60 + SessionActivityPolicy.staleGrace)
        for phase in [SessionActivityState.Phase.notePreparing, .noteSaving, .noteSaved] {
            TestSupport.expectEqual(SessionActivityPolicy.staleDate(for: SessionActivityState(phase: phase), now: now), now + interval)
        }
    }

    // MARK: The driver

    @MainActor
    private static func testANoteIsSentAgainBeforeItGoesStale() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        let recording = input(note(.recording, onPower: true))
        let shown = SessionActivityState(phase: .noteRecording, since: now - 60, onPower: true)
        driver.sync(recording, mayStart: true, now: now)
        let refresh = SessionActivityPolicy.noteStaleRefresh
        // Ticks and heartbeats in between send nothing.
        for step in stride(from: 1.0, to: refresh - 1, by: 7) { driver.sync(recording, mayStart: false, now: now + step) }
        TestSupport.expectEqual(backend.calls.count, 1)
        driver.sync(recording, mayStart: false, now: now + refresh)
        TestSupport.expectEqual(backend.calls.last,
                                .update(SessionActivityContent(state: shown,
                                                               staleDate: now + refresh + SessionActivityPolicy.noteStaleInterval)))
        // And again a refresh later, for as long as the note goes on: each before the last one went stale.
        driver.sync(recording, mayStart: false, now: now + 2 * refresh - 1)
        TestSupport.expectEqual(backend.calls.count, 2)
        driver.sync(recording, mayStart: false, now: now + 2 * refresh)
        TestSupport.expectEqual(backend.calls.count, 3)
        // A preparing and a saving note too; a ready session is not sent again.
        driver.sync(input(note(.saving, onPower: true)), mayStart: false, now: now + 2 * refresh + 1)
        driver.sync(input(note(.saving, onPower: true)), mayStart: false, now: now + 3 * refresh + 1)
        TestSupport.expectEqual(backend.calls.count, 5)
        driver.sync(input(), mayStart: false, now: now + 4 * refresh)
        driver.sync(input(), mayStart: false, now: now + 6 * refresh)
        TestSupport.expectEqual(backend.calls.count, 6)
        TestSupport.expect(backend.alerts.isEmpty, "a refresh alerted")
    }

    @MainActor
    private static func testTheLastMinutesAreOneUpdate() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        let recording = input(note(.recording, endsAt: now + 400))
        driver.sync(recording, mayStart: true, now: now)
        driver.sync(recording, mayStart: false, now: now + 99)
        TestSupport.expectEqual(backend.calls.count, 1)
        driver.sync(recording, mayStart: false, now: now + 100)
        TestSupport.expectEqual(backend.calls.last?.state?.lastMinutes, true)
        driver.sync(recording, mayStart: false, now: now + 101)
        TestSupport.expectEqual(backend.calls.count, 2)
        TestSupport.expect(backend.alerts.isEmpty, "the last minutes alerted")
    }

    /// The driver sees the note's status go with the core's ending `stopped`: "Note saved" for a beat, then ready.
    @MainActor
    private static func testAStopShowsTheSavedBeat() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(note(.recording)), mayStart: true, now: now)
        driver.sync(input(note(.saving)), mayStart: false, now: now + 1)
        let ended = input(ending: .stopped)
        driver.sync(ended, mayStart: false, now: now + 2)
        TestSupport.expectEqual(backend.calls.last?.state, SessionActivityState(phase: .noteSaved))
        let beat = SessionActivityPolicy.noteSavedDisplay
        TestSupport.expect(beat >= 2 && beat <= 5, "the beat is a moment, not a wait")
        driver.sync(ended, mayStart: false, now: now + 2 + beat - 0.01)
        TestSupport.expectEqual(backend.calls.last?.state?.phase, .noteSaved)
        driver.sync(ended, mayStart: false, now: now + 2 + beat)
        TestSupport.expectEqual(backend.calls.last?.state, SessionActivityState(phase: .ready, endsAt: now + 300, offersNote: true))
        TestSupport.expectEqual(backend.calls.map(\.state?.phase), [.noteRecording, .noteSaving, .noteSaved, .ready])
        TestSupport.expect(backend.alerts.isEmpty, "a stop alerted")
        // The ending stays in the core's measurements; it never shows the beat again.
        driver.sync(ended, mayStart: false, now: now + 60)
        TestSupport.expectEqual(backend.calls.count, 4)
    }

    @MainActor
    private static func testOnlyAStopOrTheCapShowsTheBeat() {
        for reason in [NoteEndReason.transcriptionFailed, .captureFailed, .storageFailed, .modelFailed,
                       .backgroundTimeExpired] {
            let backend = FakeActivityBackend()
            let driver = SessionActivityDriver(backend: backend)
            driver.sync(input(note(.recording)), mayStart: true, now: now)
            driver.sync(input(ending: reason), mayStart: false, now: now + 1)
            TestSupport.expectEqual(backend.calls.last?.state?.phase, .ready)
        }
        // An ending the driver never saw a note for (a start that failed) shows nothing either.
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(ending: .stopped), mayStart: true, now: now)
        TestSupport.expectEqual(backend.calls.last?.state?.phase, .ready)
    }

    @MainActor
    private static func testARecordingEndsTheBeat() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(note(.recording)), mayStart: true, now: now)
        driver.sync(input(ending: .stopped), mayStart: false, now: now + 1)
        driver.sync(input(dictation: Fixture.dictation(.starting, startedAt: now + 1.2), ending: .stopped), mayStart: false,
                    now: now + 1.2)
        TestSupport.expectEqual(backend.calls.last?.state?.phase, .recording)
        // A new note too, and its own stop starts a beat of its own.
        let other = FakeActivityBackend()
        let next = SessionActivityDriver(backend: other)
        next.sync(input(note(.recording)), mayStart: true, now: now)
        next.sync(input(ending: .stopped), mayStart: false, now: now + 1)
        next.sync(input(note(.preparing, startedAt: now + 1.5)), mayStart: false, now: now + 1.5)
        TestSupport.expectEqual(other.calls.last?.state?.phase, .notePreparing)
        next.sync(input(ending: .stopped), mayStart: false, now: now + 20)
        TestSupport.expectEqual(other.calls.last?.state?.phase, .noteSaved)
    }

    /// Exactly one update alerts: the one that says the cap ended the note and it was saved.
    @MainActor
    private static func testTheCapAlertsOnce() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(note(.recording, endsAt: now + 1)), mayStart: true, now: now)
        driver.sync(input(note(.saving)), mayStart: false, now: now + 1)
        let ended = input(ending: .reachedLimit)
        let shownAt = now + 2
        for step in stride(from: 0.0, through: 40, by: 0.5) { driver.sync(ended, mayStart: false, now: shownAt + step) }
        TestSupport.expectEqual(backend.alerts.count, 1)
        TestSupport.expectEqual(backend.alerts.first?.alert, .noteReachedLimit)
        TestSupport.expectEqual(backend.alerts.first?.state, SessionActivityState(phase: .noteSaved, atLimit: true))
        TestSupport.expectEqual(SessionActivityAlert.noteReachedLimit.title, "Note saved")
        TestSupport.expectEqual(SessionActivityAlert.noteReachedLimit.body, "It reached its time limit.")
        // It stays long enough for the screen the alert woke to show it, then gives way to ready.
        let display = SessionActivityPolicy.limitSavedDisplay
        TestSupport.expect(display > SessionActivityPolicy.noteSavedDisplay && display <= 60, "the cap's beat is \(display) s")
        TestSupport.expectEqual(backend.calls.map(\.state?.phase), [.noteRecording, .noteSaving, .noteSaved, .ready])
        TestSupport.expectEqual(backend.calls.filter { $0.state?.phase == .noteSaved }.count, 1)
    }

    /// A wait's hold gives way at once to a note starting, as to a recording.
    @MainActor
    private static func testANoteIsNeverHeldBehindAWait() {
        let backend = FakeActivityBackend()
        let driver = SessionActivityDriver(backend: backend)
        driver.sync(input(dictation: Fixture.dictation(.transcribing)), mayStart: true, now: now)
        driver.sync(input(note(.preparing), dictation: Fixture.dictation(.transcribing)), mayStart: false, now: now + 0.1)
        TestSupport.expectEqual(backend.calls.last?.state?.phase, .notePreparing)
    }

    private static func testNoteMotionAndWords() {
        TestSupport.expect(SessionActivityMotion.markDotScale(phase: .noteRecording, isStale: false, reduceMotion: false) > 1,
                           "the mark's dot does not swell while a note records")
        TestSupport.expectEqual(SessionActivityMotion.markDotScale(phase: .noteRecording, isStale: false, reduceMotion: true), 1)
        TestSupport.expectEqual(SessionActivityMotion.markDotScale(phase: .notePreparing, isStale: false, reduceMotion: false), 1)
        TestSupport.expectEqual(SessionActivityState.noteCountdownSpokenLead, "Note stops in")
        TestSupport.expectEqual(SessionActivityState.chargingSymbol, "bolt.fill")
        TestSupport.expect(SessionActivityState.chargingSpoken.hasPrefix(SessionActivityState.chargingWords),
                           "VoiceOver hears other words than the glyph's")
    }
}

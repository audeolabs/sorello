import Foundation

/// `KeyboardDictationRoute` (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Host owns the microphone, Route).
enum KeyboardDictationRouteTests {
    static var tests: [TestCase] {
        [
            ("nothingRunningOwnsNothing", testNothingRunningOwnsNothing),
            ("aFreshSessionOwnsTheMicrophone", testAFreshSessionOwnsTheMicrophone),
            ("aVoiceNoteOwnsItUntilItSaves", testAVoiceNoteOwnsItUntilItSaves),
            ("aRecordingDictationOwnsIt", testARecordingDictationOwnsIt),
            ("onlyFreshReadableStatusesOfThisSchemaCount", testOnlyFreshReadableStatusesOfThisSchemaCount),
            ("aBounceInFlightOwnsIt", testABounceInFlightOwnsIt),
            ("startsInTheKeyboardWhenEverythingHolds", testStartsInTheKeyboardWhenEverythingHolds),
            ("hostOwningTheMicrophoneSendsTheTapToTheHost", testHostOwningTheMicrophoneSendsTheTapToTheHost),
            ("onlyTheHostUnavailableModeStartsHere", testOnlyTheHostUnavailableModeStartsHere),
            ("fullAccessIsNeeded", testFullAccessIsNeeded),
            ("theSwitchIsNeeded", testTheSwitchIsNeeded),
            ("theMicrophonePermissionIsNeeded", testTheMicrophonePermissionIsNeeded),
            ("theCarriedModelIsNeeded", testTheCarriedModelIsNeeded),
            ("captureUnavailableSticksForTheInstance", testCaptureUnavailableSticksForTheInstance),
            ("anUnfinishedRecordSendsOneTapToTheHost", testAnUnfinishedRecordSendsOneTapToTheHost),
        ]
    }

    private static let good = KeyboardDictationRoute.Conditions(
        hasFullAccess: true, enabled: true, microphoneGranted: true, modelCarried: true,
        lastEndedCaptureUnavailable: false, unfinishedRecordOfAnotherProcess: false)

    private static func owns(_ status: HostStatus?, _ intent: KeyboardIntent? = nil, access: KeyboardAccess = .fullAccess,
                             now: Date = Fixture.now) -> Bool {
        KeyboardDictationRoute.hostOwnsMicrophone(access: access, status: status.map { .value($0) } ?? .absent,
                                                  intent: intent.map { .value($0) } ?? .absent,
                                                  instanceID: Fixture.instanceID, now: now)
    }

    private static func decide(_ status: HostStatus? = nil, _ intent: KeyboardIntent? = nil,
                               access: KeyboardAccess = .fullAccess,
                               _ change: (inout KeyboardDictationRoute.Conditions) -> Void = { _ in })
    -> KeyboardDictationRoute.Decision {
        var conditions = good
        change(&conditions)
        return KeyboardDictationRoute.decide(access: access, status: status.map { .value($0) } ?? .absent,
                                             intent: intent.map { .value($0) } ?? .absent,
                                             instanceID: Fixture.instanceID, now: Fixture.now, conditions: conditions)
    }

    private static func noting(_ phase: VoiceNoteStatus.Phase, _ session: HostStatus.Session) -> HostStatus {
        var status = Fixture.status(session)
        status.voiceNote = VoiceNoteStatus(phase: phase, startedAt: Fixture.now - 30, endsAt: nil, onPower: true)
        return status
    }

    private static func testNothingRunningOwnsNothing() {
        TestSupport.expect(!owns(nil), "no status owns the microphone")
        TestSupport.expect(!owns(Fixture.status(.inactive)), "an inactive host owns the microphone")
        TestSupport.expect(!owns(Fixture.status(.inactive, dictation: Fixture.dictation(.completed))),
                           "a finished dictation owns the microphone")
    }

    private static func testAFreshSessionOwnsTheMicrophone() {
        TestSupport.expect(owns(Fixture.status(.active)), "an active session does not own the microphone")
        TestSupport.expect(owns(Fixture.status(.starting)), "a starting session does not own the microphone")
        TestSupport.expect(owns(Fixture.status(.active, captureReady: false)), "a session without capture yet does not")
    }

    private static func testAVoiceNoteOwnsItUntilItSaves() {
        TestSupport.expect(owns(noting(.preparing, .inactive)), "a preparing note does not own the microphone")
        TestSupport.expect(owns(noting(.recording, .inactive)), "a recording note does not own the microphone")
        TestSupport.expect(!owns(noting(.saving, .inactive)), "a saving note owns the microphone")
    }

    private static func testARecordingDictationOwnsIt() {
        TestSupport.expect(owns(Fixture.status(.inactive, dictation: Fixture.dictation(.recording))),
                           "a recording dictation does not own the microphone")
        TestSupport.expect(!owns(Fixture.status(.inactive, dictation: Fixture.dictation(.transcribing))),
                           "a transcribing dictation owns the microphone")
    }

    private static func testOnlyFreshReadableStatusesOfThisSchemaCount() {
        let stale = Fixture.status(.active, heartbeatAt: Fixture.now - DictationProtocol.livenessTimeout - 0.1)
        TestSupport.expect(!owns(stale), "a stale session owns the microphone")
        TestSupport.expect(owns(Fixture.status(.active, heartbeatAt: Fixture.now - DictationProtocol.livenessTimeout)),
                           "a session at the liveness boundary does not")
        TestSupport.expect(!owns(Fixture.status(.active, heartbeatAt: Fixture.now + 3)), "a status from the future owns it")
        var future = Fixture.status(.active)
        future.schema = 2
        TestSupport.expect(!owns(future), "another schema's status owns the microphone")
        TestSupport.expect(!owns(Fixture.status(.active), access: .noFullAccess), "it owns it without Full Access")
        TestSupport.expect(!owns(Fixture.status(.active), access: .containerUnavailable), "it owns it without a container")
        for read in [StoreRead<HostStatus>.unreadable, .incompatible] {
            TestSupport.expect(!KeyboardDictationRoute.hostOwnsMicrophone(access: .fullAccess, status: read, intent: .absent,
                                                                          instanceID: Fixture.instanceID, now: Fixture.now),
                               "an unreadable status owns the microphone")
        }
    }

    /// This instance's own `record`, fresh and unanswered, is a bounce in flight.
    private static func testABounceInFlightOwnsIt() {
        let bounce = Fixture.intent(.record, at: Fixture.now - 5)
        TestSupport.expect(owns(nil, bounce), "a bounce in flight does not own the microphone")
        TestSupport.expect(owns(Fixture.status(.inactive, heartbeatAt: Fixture.now - 60), bounce), "a dead host hides the bounce")
        // Answered, even by a failure or a stale status: no longer in flight.
        let answered = Fixture.status(.inactive, heartbeatAt: Fixture.now - 60, dictation: Fixture.dictation(.failed, error: .sessionInactive))
        TestSupport.expect(!owns(answered, bounce), "an answered bounce owns the microphone")
        TestSupport.expect(!owns(nil, Fixture.intent(.record, instance: Fixture.otherInstanceID)),
                           "another instance's record owns it")
        TestSupport.expect(!owns(nil, Fixture.intent(.record, at: Fixture.now - DictationProtocol.pendingRecordTTL - 0.1)),
                           "an expired record owns it")
        TestSupport.expect(!owns(nil, Fixture.intent(.finish)), "a finish owns it")
        TestSupport.expect(!owns(nil, Fixture.intent(.cancel)), "a cancel owns it")
    }

    private static func testStartsInTheKeyboardWhenEverythingHolds() {
        TestSupport.expectEqual(decide(), .keyboard)
        TestSupport.expectEqual(decide(Fixture.status(.inactive, heartbeatAt: Fixture.now - 60)), .keyboard)
        TestSupport.expectEqual(decide(Fixture.status(.active, heartbeatAt: Fixture.now - 60)), .keyboard)
        TestSupport.expectEqual(decide(noting(.saving, .inactive)), .keyboard)
        // This instance's expired record is not in flight.
        TestSupport.expectEqual(decide(nil, Fixture.intent(.record, at: Fixture.now - 30)), .keyboard)
    }

    private static func testHostOwningTheMicrophoneSendsTheTapToTheHost() {
        TestSupport.expectEqual(decide(Fixture.status(.active)), .host)
        TestSupport.expectEqual(decide(Fixture.status(.starting)), .host)
        TestSupport.expectEqual(decide(noting(.recording, .inactive)), .host)
        TestSupport.expectEqual(decide(nil, Fixture.intent(.record)), .host)
    }

    /// The presenter's mode for the same fresh state must be `hostUnavailable`: here a fresh failure it shows.
    private static func testOnlyTheHostUnavailableModeStartsHere() {
        let failed = Fixture.status(.inactive, dictation: Fixture.dictation(.failed, error: .modelFailed))
        TestSupport.expectEqual(KeyboardPresenter.mode(access: .fullAccess, status: .value(failed),
                                                       intent: .value(Fixture.intent(.record, instance: Fixture.otherInstanceID)),
                                                       now: Fixture.now), .error(.modelFailed))
        TestSupport.expectEqual(decide(failed, Fixture.intent(.record, instance: Fixture.otherInstanceID)), .host)
        // Another instance's pending record shows as starting.
        TestSupport.expectEqual(decide(nil, Fixture.intent(.record, instance: Fixture.otherInstanceID)), .host)
        TestSupport.expectEqual(KeyboardDictationRoute.decide(access: .fullAccess, status: .incompatible, intent: .absent,
                                                              instanceID: Fixture.instanceID, now: Fixture.now,
                                                              conditions: good), .host)
    }

    private static func testFullAccessIsNeeded() {
        TestSupport.expectEqual(decide { $0.hasFullAccess = false }, .host)
        TestSupport.expectEqual(decide(access: .noFullAccess), .host)
        TestSupport.expectEqual(decide(access: .containerUnavailable), .host)
    }

    private static func testTheSwitchIsNeeded() {
        TestSupport.expectEqual(decide { $0.enabled = false }, .host)
    }

    private static func testTheMicrophonePermissionIsNeeded() {
        TestSupport.expectEqual(decide { $0.microphoneGranted = false }, .host)
    }

    private static func testTheCarriedModelIsNeeded() {
        TestSupport.expectEqual(decide { $0.modelCarried = false }, .host)
    }

    private static func testCaptureUnavailableSticksForTheInstance() {
        TestSupport.expectEqual(decide { $0.lastEndedCaptureUnavailable = true }, .host)
        // The machine keeps the condition for its instance: set by captureUnavailable, and by nothing else.
        var machine = KeyboardDictationMachine()
        let first = UUID()
        _ = machine.handle(.tap(attempt: first, documentID: Fixture.documentA), at: 0)
        _ = machine.handle(.captureFailed(attempt: first), at: 1)
        TestSupport.expect(machine.lastEndedCaptureUnavailable, "captureUnavailable did not stick")
        var other = KeyboardDictationMachine()
        for (index, end) in [KeyboardDictationMachine.Event.tick, .hostOwnsMicrophone].enumerated() {
            let id = UUID()
            _ = other.handle(.tap(attempt: id, documentID: Fixture.documentA), at: Double(index) * 100)
            _ = other.handle(end, at: Double(index) * 100 + KeyboardDictationTiming.startupTimeout)
            TestSupport.expect(!other.lastEndedCaptureUnavailable, "another end stuck as captureUnavailable")
        }
    }

    private static func testAnUnfinishedRecordSendsOneTapToTheHost() {
        TestSupport.expectEqual(decide { $0.unfinishedRecordOfAnotherProcess = true }, .host)
    }
}

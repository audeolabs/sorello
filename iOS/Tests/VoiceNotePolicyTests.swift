import Foundation

/// The voice note's pure rules (ARCHITECTURE.md, "Voice notes"): the cap, what a session's end and a failed
/// preparation mean for a note, and the text a run puts in its note. Invented text only.
enum VoiceNotePolicyTests {
    static var tests: [TestCase] {
        [
            ("batteryEndsAnHourAfterTheStart", testBatteryEndsAnHourAfterTheStart),
            ("anUnplugRestartsTheHour", testAnUnplugRestartsTheHour),
            ("powerEndsAMarginBeforeTheActivityLifetime", testPowerEndsAMarginBeforeTheActivityLifetime),
            ("theActivityLifetimeBoundsBatteryToo", testTheActivityLifetimeBoundsBatteryToo),
            ("aBackwardClockJumpEndsTheNote", testABackwardClockJumpEndsTheNote),
            ("onlyBatteryPublishesADeadline", testOnlyBatteryPublishesADeadline),
            ("sessionEndsMapToNoteReasons", testSessionEndsMapToNoteReasons),
            ("failedPreparationsMapToNoteReasons", testFailedPreparationsMapToNoteReasons),
            ("runTextFollowsTheRules", testRunTextFollowsTheRules),
            ("runTextFitsItsPlace", testRunTextFitsItsPlace),
            ("formatterReadsTheSettingsWhenItRuns", testFormatterReadsTheSettingsWhenItRuns),
        ]
    }

    private static let start = Fixture.now
    private static let hour: TimeInterval = 3600

    private static func reached(at now: Date, unplugged: Date? = nil, power: PowerSource,
                                activity: Date? = nil) -> Bool {
        VoiceNotePolicy.hasReachedCap(startedAt: start, lastUnpluggedAt: unplugged, power: power,
                                      activityStartedAt: activity, now: now)
    }

    private static func endsAt(unplugged: Date? = nil, power: PowerSource, activity: Date? = nil) -> Date {
        VoiceNotePolicy.endsAt(startedAt: start, lastUnpluggedAt: unplugged, power: power, activityStartedAt: activity)
    }

    // MARK: Cap

    /// On battery, and with the power state unknown, a note ends 60 minutes after its start.
    private static func testBatteryEndsAnHourAfterTheStart() {
        TestSupport.expectEqual(VoiceNotePolicy.batteryDuration, hour)
        for power in [PowerSource.battery, .unknown] {
            TestSupport.expectEqual(endsAt(power: power), start + hour)
            TestSupport.expect(!reached(at: start + hour, power: power), "\(power) ended at the hour")
            TestSupport.expect(reached(at: start + hour + 0.1, power: power), "\(power) went past the hour")
            // An unplug before the note started counts from the start.
            TestSupport.expectEqual(endsAt(unplugged: start - 600, power: power), start + hour)
        }
    }

    /// An unplug after the start gives the note an hour from the unplug.
    private static func testAnUnplugRestartsTheHour() {
        let unplugged = start + 2 * hour
        TestSupport.expectEqual(endsAt(unplugged: unplugged, power: .battery), unplugged + hour)
        TestSupport.expect(!reached(at: unplugged + hour - 1, unplugged: unplugged, power: .battery), "ended early")
        TestSupport.expect(reached(at: unplugged + hour + 0.1, unplugged: unplugged, power: .battery), "ran on")
    }

    /// With power connected nothing counts down; the note ends a margin before the session's Live Activity reaches
    /// ActivityKit's eight hours, counted from the note's start when no activity shows, so the activity is still
    /// there to show the note was saved.
    private static func testPowerEndsAMarginBeforeTheActivityLifetime() {
        TestSupport.expectEqual(VoiceNotePolicy.activityLifetime, 8 * hour)
        TestSupport.expectEqual(VoiceNotePolicy.activityMargin, 5 * 60)
        let bound = 8 * hour - 5 * 60
        TestSupport.expect(!reached(at: start + 7 * hour, unplugged: start, power: .connected), "power ended at an hour")
        TestSupport.expectEqual(endsAt(power: .connected), start + bound)
        TestSupport.expect(!reached(at: start + bound, power: .connected), "ended before the bound")
        TestSupport.expect(reached(at: start + bound + 0.1, power: .connected), "outlived the bound")
        let activity = start - 3 * hour
        TestSupport.expectEqual(endsAt(power: .connected, activity: activity), activity + bound)
        TestSupport.expect(reached(at: activity + bound + 0.1, power: .connected, activity: activity),
                           "outlived the activity")
        TestSupport.expect(!reached(at: activity + bound - 1, power: .connected, activity: activity),
                           "ended before the activity")
    }

    /// Nothing records without a visible state: on battery too, the activity's lifetime ends a note first when it
    /// comes first.
    private static func testTheActivityLifetimeBoundsBatteryToo() {
        let activity = start - 7.5 * hour
        TestSupport.expectEqual(endsAt(power: .battery, activity: activity), activity + 8 * hour - 5 * 60)
        TestSupport.expect(reached(at: start + 0.5 * hour - 5 * 60 + 0.1, power: .battery, activity: activity), "ran past it")
    }

    /// A clock that jumps back past the tolerance ends the note, whatever the power.
    private static func testABackwardClockJumpEndsTheNote() {
        for power in [PowerSource.battery, .unknown, .connected] {
            TestSupport.expect(!reached(at: start - 1, power: power), "\(power): a small skew ended the note")
            TestSupport.expect(reached(at: start - 2.1, power: power), "\(power): a jump back kept the note")
            TestSupport.expect(reached(at: start + 60, unplugged: start + 600, power: power == .connected ? .battery : power),
                               "\(power): a jump back before the unplug kept the note")
            TestSupport.expect(reached(at: start, power: power, activity: start + 10),
                               "\(power): a jump back before the activity kept the note")
        }
    }

    /// `status.json` carries a deadline on battery only: with power connected nothing counts down.
    private static func testOnlyBatteryPublishesADeadline() {
        TestSupport.expectEqual(VoiceNotePolicy.publishedEnd(startedAt: start, lastUnpluggedAt: nil, power: .connected,
                                                             activityStartedAt: nil), nil)
        for power in [PowerSource.battery, .unknown] {
            TestSupport.expectEqual(VoiceNotePolicy.publishedEnd(startedAt: start, lastUnpluggedAt: start + 60,
                                                                 power: power, activityStartedAt: nil),
                                    start + 60 + hour)
        }
    }

    // MARK: Endings

    private static func testSessionEndsMapToNoteReasons() {
        let cases: [(SessionEndReason, NoteEndReason)] = [
            (.user, .sessionEnded), (.idleExpired, .sessionEnded), (.interrupted, .interrupted),
            (.engineFailed, .captureFailed), (.mediaServicesReset, .captureFailed),
            (.startFailed(.microphonePermissionDenied), .microphonePermissionDenied),
            (.startFailed(.audioSessionFailed), .captureFailed),
        ]
        for (session, note) in cases { TestSupport.expectEqual(VoiceNotePolicy.endReason(after: session), note) }
    }

    private static func testFailedPreparationsMapToNoteReasons() {
        TestSupport.expectEqual(VoiceNotePolicy.preparationFailure(model: .unavailable), .modelUnavailable)
        TestSupport.expectEqual(VoiceNotePolicy.preparationFailure(model: .failed), .modelFailed)
        for model in [HostStatus.Model.notPrepared, .preparing, .ready] {
            TestSupport.expectEqual(VoiceNotePolicy.preparationFailure(model: model), nil)
        }
    }

    // MARK: Formatting

    private static func text(_ pieces: [String], before: String = "", after: String = "", numbers: Bool = true,
                             delimiters: Bool = true) -> String {
        NoteRunText.format(pieces, before: before[...], after: after[...], spokenNumbers: numbers,
                           spokenDelimiters: delimiters)
    }

    /// The rules apply to the run as a whole: pieces joined by single spaces, so a phrase split across chunks reads as
    /// one; spoken numbers and delimiters as asked; and "press enter" is only words.
    private static func testRunTextFollowsTheRules() {
        TestSupport.expectEqual(text(["Step three takes", "twenty minutes."]), "Step 3 takes 20 minutes.")
        TestSupport.expectEqual(text(["Step three takes", "twenty minutes."], numbers: false),
                                "Step three takes twenty minutes.")
        TestSupport.expectEqual(text(["Set quote ship", "it end quote now."]), "Set \"ship it\" now.")
        TestSupport.expectEqual(text(["Set quote ship", "it end quote now."], delimiters: false),
                                "Set quote ship it end quote now.")
        TestSupport.expectEqual(text(["Send the draft, press enter."]), "Send the draft, press enter.")
        TestSupport.expectEqual(text([]), "")
        TestSupport.expectEqual(text(["", ""]), "")
    }

    /// The run is fitted to the note's text around its place, as a dictation to the text around the cursor.
    private static func testRunTextFitsItsPlace() {
        TestSupport.expectEqual(text(["Then more eggs."], before: "Groceries, "), "then more eggs.")
        TestSupport.expectEqual(text(["Then more eggs."], before: "Groceries"), " then more eggs.")
        TestSupport.expectEqual(text(["Then more eggs."], before: "Done.\n", after: "Next line"), "Then more eggs. ")
        TestSupport.expectEqual(text(["Then more eggs."], before: "Done. ", after: ". Later"), "Then more eggs")
    }

    /// The app's formatter reads the settings each time it runs, so a run merged later uses the settings of then.
    private static func testFormatterReadsTheSettingsWhenItRuns() {
        let suite = "SorelloIOSTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SorelloSettings(defaults: UserDefaults(suiteName: suite)!)
        let format = NoteRunText.formatter(settings: settings)
        TestSupport.expectEqual(format(["Step three takes", "twenty minutes."], "", ""), "Step 3 takes 20 minutes.")
        settings.spokenNumbersEnabled = false
        TestSupport.expectEqual(format(["Step three takes", "twenty minutes."], "", ""), "Step three takes twenty minutes.")
        settings.pressEnterEnabled = true
        TestSupport.expectEqual(format(["Send it, press enter."], "", ""), "Send it, press enter.")
    }
}

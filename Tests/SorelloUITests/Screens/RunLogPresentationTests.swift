import Foundation
import Testing
@testable import SorelloUI

/// When a Run Log entry happened, how it ended, and what it offers.
struct RunLogPresentationTests {
    /// A fixed calendar and a 24-hour locale, so the expected strings do not depend on the machine.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Wednesday 11 November 2026, 15:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_411_000)

    private func label(_ secondsAgo: TimeInterval) -> String {
        RunLogTime.label(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale)
    }

    @Test func underAMinuteIsJustNow() {
        #expect(label(0) == "Just now")
        #expect(label(59) == "Just now")
    }

    @Test func aDateInTheFutureIsJustNow() {
        #expect(label(-300) == "Just now")
    }

    @Test func underAnHourCountsMinutes() {
        #expect(label(60) == "1 min ago")
        #expect(label(45 * 60 + 30) == "45 min ago")
    }

    @Test func earlierTodayIsTheTime() {
        #expect(label(3600) == "14:30")
        #expect(label(5 * 3600) == "10:30")
    }

    @Test func yesterdayNamesTheDay() {
        #expect(label(16 * 3600) == "Yesterday, 23:30")
        #expect(label(28 * 3600) == "Yesterday, 11:30")
    }

    @Test func thisWeekIsTheWeekday() {
        #expect(label(2 * 86400) == "Monday, 15:30")
        #expect(label(6 * 86400) == "Thursday, 15:30")
    }

    @Test func olderIsTheDate() {
        #expect(label(7 * 86400) == "4 Nov, 15:30")
    }

    @Test func onlyFailuresAreProblems() {
        #expect(!RunLogOutcome.inserted.isProblem)
        #expect(!RunLogOutcome.leftOnClipboard.isProblem)
        #expect(RunLogOutcome.insertionFailed.isProblem)
        #expect(RunLogOutcome.transcriptionFailed.isProblem)
    }

    @Test func aFailedTranscriptHasNothingToShowOrCopy() {
        let failed = RunLogItem(id: "a", date: now, heard: "", text: "", outcome: .transcriptionFailed, duration: 4)
        #expect(failed.display == .none)
        #expect(!failed.canCopy)
    }

    @Test func aPastedDictationShowsWhatWasPasted() {
        let pasted = RunLogItem(id: "b", date: now, heard: "pack my box with five dozen liquor jugs",
                                text: "Pack my box with five dozen liquor jugs.", outcome: .inserted, duration: 4)
        #expect(pasted.display == .text("Pack my box with five dozen liquor jugs."))
        #expect(pasted.canCopy)
    }

    @Test func aCommandAloneShowsWhatWasHeard() {
        let command = RunLogItem(id: "c", date: now, heard: "press enter", text: "", outcome: .inserted, duration: 1)
        #expect(command.display == .commandOnly(heard: "press enter"))
        #expect(command.canCopy)
    }

    @Test func aCommandThatWentThroughSaysWhatItDidNotThatItPasted() {
        let command = RunLogItem(id: "c", date: now, heard: "press enter", text: "", outcome: .inserted, duration: 1)
        #expect(command.outcomeLabel == "Return pressed")
        let blocked = RunLogItem(id: "d", date: now, heard: "press enter", text: "", outcome: .insertionFailed,
                                 duration: 1)
        #expect(blocked.outcomeLabel == RunLogOutcome.insertionFailed.label)
        let pasted = RunLogItem(id: "e", date: now, heard: "pack my box", text: "Pack my box.", outcome: .inserted,
                                duration: 2)
        #expect(pasted.outcomeLabel == RunLogOutcome.inserted.label)
    }

    @Test func durationsAreMinutesAndSeconds() {
        #expect(RunLogItem(id: "a", date: now, heard: "", text: "", outcome: .inserted, duration: 4.4).durationLabel == "0:04")
        #expect(RunLogItem(id: "a", date: now, heard: "", text: "", outcome: .inserted, duration: 72).durationLabel == "1:12")
    }
}

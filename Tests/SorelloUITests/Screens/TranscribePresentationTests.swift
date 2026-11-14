import Foundation
import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 8, "Windows", Transcribe File: what the window says in each state, which files it takes
/// and when, and what each failure offers.
struct TranscribePresentationTests {
    // MARK: Progress

    @Test func progressIsMinutesAndSecondsOfTheLength() {
        #expect(TranscribeWords.progress(read: 250, length: 3482) == "4:10 of 58:02")
        #expect(TranscribeWords.progress(read: 0, length: 5) == "0:00 of 0:05")
        #expect(TranscribeWords.progress(read: 59.9, length: 3599.9) == "0:59 of 59:59")
    }

    /// Hours appear for both numbers once the length has them, so the two always read alike.
    @Test func progressHasHoursWhenTheLengthHasThem() {
        #expect(TranscribeWords.progress(read: 250, length: 4682) == "0:04:10 of 1:18:02")
        #expect(TranscribeWords.progress(read: 4410, length: 4682) == "1:13:30 of 1:18:02")
        #expect(TranscribeWords.progress(read: 3600, length: 3600) == "1:00:00 of 1:00:00")
        #expect(TranscribeWords.progress(read: 1, length: 36_000) == "0:00:01 of 10:00:00")
    }

    /// A compressed file's length may be an estimate: the amount read is never shown as more than it.
    @Test func theAmountReadIsNeverMoreThanTheLength() {
        #expect(TranscribeWords.progress(read: 4000, length: 3482) == "58:02 of 58:02")
        #expect(TranscribeWords.fraction(read: 4000, length: 3482) == 1)
        #expect(TranscribeWords.progress(read: -3, length: 60) == "0:00 of 1:00")
        #expect(TranscribeWords.fraction(read: -3, length: 60) == 0)
    }

    /// Until the length is known the bar travels and no words show.
    @Test func anUnknownLengthHasNoWordsAndATravellingBar() {
        for length in [0, -1, .nan, .infinity] as [TimeInterval] {
            #expect(TranscribeWords.progress(read: 0, length: length) == nil)
            #expect(TranscribeWords.fraction(read: 0, length: length) == nil)
        }
        #expect(TranscribeWords.fraction(read: .nan, length: 10) == 0)
    }

    @Test func theBarFillsWithTheShareRead() throws {
        let fraction = try #require(TranscribeWords.fraction(read: 250, length: 1000))
        #expect(abs(fraction - 0.25) < 1e-12)
    }

    // MARK: States

    /// One file at a time: while one is preparing or being transcribed, the window takes no other.
    @Test func theWindowTakesFilesExceptWhileOneIsUnderWay() {
        let file = "a.wav"
        #expect(TranscribeState.empty.takesFiles)
        #expect(!TranscribeState.preparing(file: file).takesFiles)
        #expect(!TranscribeState.transcribing(file: file, read: 1, length: 2).takesFiles)
        #expect(TranscribeState.done(file: file, text: "Invented words.").takesFiles)
        #expect(TranscribeState.nothingHeard(file: file).takesFiles)
        for reason in TranscribeFailure.allCases {
            #expect(TranscribeState.failed(file: file, reason: reason).takesFiles)
        }
    }

    @Test func everyStateButEmptyNamesItsFile() {
        let file = "harbour meeting.m4a"
        #expect(TranscribeState.empty.fileName == nil)
        let states: [TranscribeState] = [
            .preparing(file: file), .transcribing(file: file, read: 1, length: 2),
            .done(file: file, text: "Invented words."), .nothingHeard(file: file),
            .failed(file: file, reason: .cannotOpen),
        ]
        #expect(states.allSatisfy { $0.fileName == file })
    }

    // MARK: Failures

    @Test func eachFailureHasItsOwnLine() {
        let lines = TranscribeFailure.allCases.map { TranscribeWords.reason($0, appName: "Sorello") }
        #expect(lines == [
            "Sorello can’t read this file",
            "This file can’t be opened",
            "Speech model not downloaded",
            "No speech model for this Mac yet",
            "Speech model unavailable",
            "Couldn’t transcribe this file",
        ])
        #expect(TranscribeWords.reason(.unreadable, appName: "Sorello Nightly") == "Sorello Nightly can’t read this file")
    }

    /// Under a file Sorello cannot read, the formats it does read; nothing under the others.
    @Test func onlyAnUnreadableFileSaysWhatCanBeRead() throws {
        let formats = try #require(TranscribeWords.detail(.unreadable))
        for format in ["WAV", "AIFF", "CAF", "FLAC", "MP3", "M4A", "Ogg", "MP4", "MOV"] {
            #expect(formats.contains(format), "\(format)")
        }
        #expect(!formats.contains("WebM") && !formats.contains("MKV"))
        #expect(TranscribeFailure.allCases.filter { TranscribeWords.detail($0) != nil } == [.unreadable])
    }

    @Test func aFailureOffersTheRemedyThatFitsIt() {
        #expect(TranscribeFailure.modelMissing.remedy == .download)
        #expect(TranscribeFailure.modelUnavailable.remedy == .retry)
        #expect(TranscribeFailure.failed.remedy == .tryAgain)
        for reason in [TranscribeFailure.unreadable, .cannotOpen, .noModelForThisMac] {
            #expect(reason.remedy == nil, "\(reason)")
        }
        #expect([TranscribeRemedy.download, .retry, .tryAgain].map(\.title) == ["Download…", "Retry", "Try Again"])
    }

    @MainActor
    @Test func eachRemedyRunsItsAction() {
        var ran: [String] = []
        let actions = TranscribeActions(download: { ran.append("download") }, retry: { ran.append("retry") },
                                        tryAgain: { ran.append("try again") })
        for remedy in [TranscribeRemedy.download, .retry, .tryAgain] { actions.perform(remedy) }
        #expect(ran == ["download", "retry", "try again"])
    }

    // MARK: Drops

    /// A drop is exactly one file's address, and only while the window takes files.
    @Test func theWindowTakesADropOfExactlyOneFile() {
        let done = TranscribeState.done(file: "a.wav", text: "Invented words.")
        #expect(TranscribeDrop.accepts(itemCount: 1, fileCount: 1, state: .empty))
        #expect(TranscribeDrop.accepts(itemCount: 1, fileCount: 1, state: done))
        #expect(TranscribeDrop.accepts(itemCount: 1, fileCount: 1, state: .nothingHeard(file: "a.wav")))
        #expect(TranscribeDrop.accepts(itemCount: 1, fileCount: 1, state: .failed(file: "a.wav", reason: .failed)))
        #expect(!TranscribeDrop.accepts(itemCount: 2, fileCount: 2, state: .empty))
        #expect(!TranscribeDrop.accepts(itemCount: 2, fileCount: 1, state: .empty))
        #expect(!TranscribeDrop.accepts(itemCount: 1, fileCount: 0, state: .empty))
        #expect(!TranscribeDrop.accepts(itemCount: 0, fileCount: 0, state: .empty))
        #expect(!TranscribeDrop.accepts(itemCount: 1, fileCount: 1, state: .preparing(file: "a.wav")))
        #expect(!TranscribeDrop.accepts(itemCount: 1, fileCount: 1,
                                        state: .transcribing(file: "a.wav", read: 1, length: 9)))
    }

    // MARK: Chrome

    /// The window can be made smaller than it opens, down to a minimum, as the main window can.
    @MainActor
    @Test func theWindowOpensLargerThanItsMinimum() {
        let kind = WindowChrome.Kind.transcribe
        #expect(kind.minimumSize.width < kind.defaultSize.width)
        #expect(kind.minimumSize.height < kind.defaultSize.height)
    }
}

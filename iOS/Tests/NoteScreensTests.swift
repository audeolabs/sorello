import Foundation

/// What the Notes screens show for a state (ARCHITECTURE.md, "Host app", Notes). Pure. Test text is invented.
enum NoteScreensTests {
    static var tests: [TestCase] {
        [
            ("notesScreenForEachVaultState", testNotesScreenForEachVaultState),
            ("onlyTheUnlockedScreenShowsNotes", testOnlyTheUnlockedScreenShowsNotes),
            ("recordIsStopWhileANoteIsInProgress", testRecordIsStopWhileANoteIsInProgress),
            ("noteScreenIsRecordingOrEditingNeverBoth", testNoteScreenIsRecordingOrEditingNeverBoth),
            ("aLockedNoteScreenShowsNoText", testALockedNoteScreenShowsNoText),
            ("liveTextIsTheVaultsTextWithTheTailAtTheRun", testLiveTextIsTheVaultsTextWithTheTailAtTheRun),
            ("rowPreviewIsTheStartOnOneLine", testRowPreviewIsTheStartOnOneLine),
            ("rowDateStyle", testRowDateStyle),
            ("unreadableNotesAreSaid", testUnreadableNotesAreSaid),
            ("snippetAroundTheFirstMatch", testSnippetAroundTheFirstMatch),
            ("resumePlaceIsTheCursor", testResumePlaceIsTheCursor),
            ("everyRefusalHasASentence", testEveryRefusalHasASentence),
        ]
    }

    private static let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!
    private static let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!

    private static func testNotesScreenForEachVaultState() {
        TestSupport.expectEqual(NotesScreen(vault: .noVault, canMakeVault: true, offersRecoveryCode: false), .firstUse)
        TestSupport.expectEqual(NotesScreen(vault: .noVault, canMakeVault: false, offersRecoveryCode: false), .needsPasscode)
        TestSupport.expectEqual(NotesScreen(vault: .unlocked, canMakeVault: false, offersRecoveryCode: true), .recoveryOffer)
        TestSupport.expectEqual(NotesScreen(vault: .unlocked, canMakeVault: false, offersRecoveryCode: false), .unlocked)
        TestSupport.expectEqual(NotesScreen(vault: .locked, canMakeVault: false, offersRecoveryCode: true), .locked)
        TestSupport.expectEqual(NotesScreen(vault: .secretMissing, canMakeVault: false, offersRecoveryCode: false), .secretMissing)
    }

    private static func testOnlyTheUnlockedScreenShowsNotes() {
        let all: [NotesScreen] = [.needsPasscode, .firstUse, .recoveryOffer, .locked, .unlocked, .secretMissing]
        TestSupport.expectEqual(all.filter(\.showsNotes), [.unlocked])
        // Recording needs a vault, never an unlock.
        TestSupport.expectEqual(all.filter(\.offersRecord), [.locked, .unlocked])
        TestSupport.expectEqual(all.filter(\.offersUnlock), [.locked])
    }

    private static func testRecordIsStopWhileANoteIsInProgress() {
        TestSupport.expectEqual(NoteRecordButton(offersRecord: true, note: nil), .record)
        TestSupport.expectEqual(NoteRecordButton(offersRecord: false, note: nil), nil)
        for offers in [true, false] {
            TestSupport.expectEqual(NoteRecordButton(offersRecord: offers, note: .preparing), .stop)
            TestSupport.expectEqual(NoteRecordButton(offersRecord: offers, note: .recording), .stop)
            TestSupport.expectEqual(NoteRecordButton(offersRecord: offers, note: .saving), .saving)
        }
        TestSupport.expectEqual(NoteRecordButton.stop.accent, .coral)
        TestSupport.expectEqual(NoteRecordButton.record.accent, nil)
        TestSupport.expect(!NoteRecordButton.saving.isEnabled, "Saving can be pressed")
    }

    private static func testNoteScreenIsRecordingOrEditingNeverBoth() {
        func mode(_ recording: UUID?, _ phase: VoiceNoteStatus.Phase?) -> NoteScreenMode {
            NoteScreenMode(isUnlocked: true, noteID: id, recordingNoteID: recording, phase: phase)
        }
        TestSupport.expectEqual(mode(nil, nil), .editing(canResume: true))
        TestSupport.expectEqual(mode(id, .preparing), .preparing)
        TestSupport.expectEqual(mode(id, .recording), .recording)
        TestSupport.expectEqual(mode(id, .saving), .saving)
        // Another note in progress or saving: this one is edited, and Resume waits.
        TestSupport.expectEqual(mode(other, .recording), .editing(canResume: false))
        TestSupport.expectEqual(mode(other, .saving), .editing(canResume: false))
        for state in [mode(id, .preparing), mode(id, .recording), mode(id, .saving), mode(nil, nil)] {
            TestSupport.expect(state.isLive != state.isEditing, "\(state) is both live and edited, or neither")
            TestSupport.expect(state.showsText, "\(state) shows no text unlocked")
        }
        TestSupport.expect(mode(id, .recording).offersStop && mode(id, .preparing).offersStop, "no Stop while recording")
        TestSupport.expect(!mode(id, .saving).offersStop, "Stop while saving")
        TestSupport.expectEqual(mode(id, .preparing).status, "Preparing the speech model. Nothing is recorded yet.")
        TestSupport.expectEqual(mode(id, .recording).status, "Recording")
        TestSupport.expectEqual(mode(id, .recording).accent, .coral)
        TestSupport.expectEqual(mode(id, .preparing).accent, .glacier)
        TestSupport.expectEqual(mode(nil, nil).status, nil)
    }

    private static func testALockedNoteScreenShowsNoText() {
        func mode(_ recording: UUID?, _ phase: VoiceNoteStatus.Phase?) -> NoteScreenMode {
            NoteScreenMode(isUnlocked: false, noteID: id, recordingNoteID: recording, phase: phase)
        }
        TestSupport.expectEqual(mode(id, .recording), .locked(inProgress: true))
        TestSupport.expectEqual(mode(id, .preparing), .locked(inProgress: true))
        TestSupport.expectEqual(mode(id, .saving), .locked(inProgress: false))
        TestSupport.expectEqual(mode(other, .recording), .locked(inProgress: false))
        TestSupport.expectEqual(mode(nil, nil), .locked(inProgress: false))
        for state in [mode(id, .recording), mode(nil, nil)] {
            TestSupport.expect(!state.showsText && !state.isLive && !state.isEditing, "\(state) shows text locked")
        }
        TestSupport.expect(mode(id, .recording).offersStop, "a locked recording note offers no Stop")
    }

    private static func run(_ place: NoteRunPlace, _ pieces: [String], recording: Bool) -> NotePendingRun {
        NotePendingRun(id: UUID(), place: place, startedAt: Fixture.now, pieces: pieces, isRecording: recording,
                       isReadable: true)
    }

    private static func note(body: String, runs: [NotePendingRun]) -> Note {
        let text = NoteMerge.merge(runs.map { NoteRunContent(place: $0.place, pieces: $0.pieces) }, into: body,
                                   format: NoteFixture.format)
        return Note(id: id, text: text, body: body, created: Fixture.now, modified: Fixture.now, pendingRuns: runs)
    }

    private static func testLiveTextIsTheVaultsTextWithTheTailAtTheRun() {
        // A resume in the middle: the tail follows the run's words, before the rest of the note.
        let middle = note(body: "First line. Last line.",
                          runs: [run(.offset(12), ["middle words"], recording: true)])
        let live = NoteLiveText(note: middle, provisional: "  still coming ", format: NoteFixture.format)
        TestSupport.expectEqual(live.before + live.after, middle.text)
        TestSupport.expectEqual(live.before, "First line. middle words ")
        TestSupport.expectEqual(live.provisional, "still coming ")
        TestSupport.expectEqual(live.after, "Last line.")
        // An earlier run that has ended goes first; the recording one is placed in the text it made.
        let two = note(body: "Body", runs: [run(.end, ["ended run"], recording: false),
                                           run(.end, ["live run"], recording: true)])
        let atEnd = NoteLiveText(note: two, provisional: "tail", format: NoteFixture.format)
        TestSupport.expectEqual(atEnd.before, "Body ended run live run")
        TestSupport.expectEqual(atEnd.provisional, " tail")
        TestSupport.expectEqual(atEnd.after, "")
        // Not recording: the text alone, and a blank tail shows nothing.
        let still = note(body: "Kept text", runs: [])
        TestSupport.expectEqual(NoteLiveText(note: still, provisional: " ", format: NoteFixture.format).provisional, "")
        TestSupport.expectEqual(NoteLiveText(note: still, provisional: "", format: NoteFixture.format).before, "Kept text")
    }

    private static func testRowPreviewIsTheStartOnOneLine() {
        TestSupport.expectEqual(NoteRowText.preview("  Shopping list\n\n  pears,\tfigs  "), "Shopping list pears, figs")
        TestSupport.expectEqual(NoteRowText.preview(" \n\t"), nil)
        TestSupport.expectEqual(NoteRowText.preview(""), nil)
        TestSupport.expectEqual(NoteRowText.preview(String(repeating: "x", count: 400))?.count, NoteRowText.previewLength)
        let words = NoteRowText.preview(String(repeating: "word ", count: 100))!
        TestSupport.expect(words.count <= NoteRowText.previewLength && !words.hasSuffix(" "), "\(words.count) characters")
    }

    private static func testRowDateStyle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        TestSupport.expectEqual(NoteRowText.dateStyle(now.addingTimeInterval(-3600), now: now, calendar: calendar), .time)
        TestSupport.expectEqual(NoteRowText.dateStyle(now.addingTimeInterval(-86_400), now: now, calendar: calendar), .dayAndMonth)
        TestSupport.expectEqual(NoteRowText.dateStyle(now.addingTimeInterval(-40 * 86_400), now: now, calendar: calendar), .fullDate)
    }

    private static func testUnreadableNotesAreSaid() {
        TestSupport.expectEqual(NoteRowText.unreadable(0), nil)
        TestSupport.expectEqual(NoteRowText.unreadable(1), "1 note couldn’t be opened.")
        TestSupport.expectEqual(NoteRowText.unreadable(3), "3 notes couldn’t be opened.")
    }

    /// The highlighted parts of a snippet.
    private static func marked(_ snippet: NoteSnippet) -> [String] {
        let characters = Array(snippet.text)
        return snippet.highlights.map { String(characters[$0]) }
    }

    private static func testSnippetAroundTheFirstMatch() {
        // Near the start: no cut at the front, and line breaks show as spaces.
        let short = NoteSnippet(text: "Tulips\nand daffodils", matches: [11 ..< 15])
        TestSupport.expectEqual(short.text, "Tulips and daffodils")
        TestSupport.expectEqual(marked(short), ["daff"])
        // Deep in a long note: it starts at a word in the lead, and both cuts are marked.
        let words = (1 ... 80).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let target = text.distance(from: text.startIndex, to: text.range(of: "word40")!.lowerBound)
        let snippet = NoteSnippet(text: text, matches: [target ..< target + 6, target + 7 ..< target + 13])
        TestSupport.expect(snippet.text.hasPrefix("…word"), "the front cut is not at a word: \(snippet.text)")
        TestSupport.expect(snippet.text.hasSuffix("…"), "the back cut is not marked")
        TestSupport.expect(snippet.text.count <= NoteSnippet.length + 2, "the snippet is too long")
        TestSupport.expectEqual(marked(snippet), ["word40", "word41"])
        let lead = snippet.text.distance(from: snippet.text.startIndex, to: snippet.text.range(of: "word40")!.lowerBound)
        TestSupport.expect(lead <= NoteSnippet.lead + 1, "the match is too far in")
        // No match: the start of the note.
        TestSupport.expectEqual(NoteSnippet(text: " Plain\nnote", matches: []), NoteSnippet(text: "Plain note", matches: []))
        TestSupport.expectEqual(NoteSnippet(text: "Plain note", matches: []).highlights, [])
    }

    private static func testResumePlaceIsTheCursor() {
        let text = "Tea 🍵 time"
        let index = { (offset: Int) in text.index(text.startIndex, offsetBy: offset) }
        // After the emoji: six UTF-16 units in.
        TestSupport.expectEqual(NoteCursor.place(selection: index(5) ..< index(5), in: text), .offset(6))
        // A selection: its end.
        TestSupport.expectEqual(NoteCursor.place(selection: index(0) ..< index(3), in: text), .offset(3))
        TestSupport.expectEqual(NoteCursor.place(selection: text.endIndex ..< text.endIndex, in: text), .end)
        TestSupport.expectEqual(NoteCursor.place(selection: nil, in: text), .end)
    }

    private static func testEveryRefusalHasASentence() {
        let errors: [NoteError] = [.noPasscode, .vaultExists, .noVault, .secretMissing, .locked, .authenticationCancelled,
                                   .keyStoreFailed, .unavailable, .storageFailed, .noRecoveryCode, .malformedRecoveryCode,
                                   .wrongRecoveryCode, .noSuchNote, .noteIsRecording, .runEnded]
        for error in errors { TestSupport.expect(!error.message.isEmpty, "\(error) has no sentence") }
        let reasons: [NoteEndReason] = [.reachedLimit, .sessionEnded, .interrupted, .captureFailed,
                                        .microphonePermissionDenied, .modelUnavailable, .modelFailed,
                                        .transcriptionFailed, .storageFailed, .backgroundTimeExpired, .noteGone]
        for reason in reasons {
            TestSupport.expect(reason.message?.isEmpty == false, "\(reason) has no sentence")
            TestSupport.expectEqual(NoteStartOutcome.failed(reason).message, reason.message)
        }
        TestSupport.expectEqual(NoteEndReason.stopped.message, nil)
        let needs: [NoteNeedsApp] = [.noVault, .microphone, .locked, .foreground, .liveActivity]
        for need in needs { TestSupport.expect(NoteStartOutcome.needsApp(need).message != nil, "\(need) has no sentence") }
        TestSupport.expect(NoteStartOutcome.busy.message != nil, "busy has no sentence")
        for outcome in [NoteStartOutcome.started, .startedInBackground, .stopped] {
            TestSupport.expectEqual(outcome.message, nil)
        }
    }
}

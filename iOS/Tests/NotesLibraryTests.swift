import Foundation

/// The session core's note as the Notes screens see it: a start writes a run with the fixture's recorder, each piece is
/// written and reported, and a stop ends the run (ARCHITECTURE.md, "Voice notes").
@MainActor
final class FakeNoteHost: NoteRecordingHost {
    var onNoteChange: (@MainActor (NoteChange) -> Void)?
    var onNoteProvisional: (@MainActor (_ noteID: UUID, _ provisional: String) -> Void)?
    private let notes: NoteFixture
    private var writer: NoteRunWriter?
    private(set) var targets: [NoteRunTarget] = []
    /// What the next start returns instead of starting.
    var refuse: NoteStartOutcome?

    init(_ notes: NoteFixture) {
        self.notes = notes
    }

    var voiceNoteID: UUID? { writer?.noteID }

    func userStartNote(_ target: NoteRunTarget) -> NoteStartOutcome {
        targets.append(target)
        if let refuse { return refuse }
        guard writer == nil else { return .busy }
        do {
            writer = try notes.recorder.beginRun(target)
        } catch NoteError.noVault {
            return .needsApp(.noVault)
        } catch {
            return .failed(.storageFailed)
        }
        onNoteChange?(.started(noteID: writer!.noteID))
        return .started
    }

    /// A report: its settled text is written, then its tail goes to the observer.
    func report(settled: String, provisional: String) {
        guard let writer else { return }
        if !settled.isEmpty {
            try! writer.append(settled)
            onNoteChange?(.wrote(noteID: writer.noteID))
        }
        onNoteProvisional?(writer.noteID, provisional)
    }

    func stopNote() -> Bool {
        guard writer != nil else { return false }
        end(.stopped)
        return true
    }

    func end(_ reason: NoteEndReason) {
        guard let writer else { return }
        self.writer = nil
        writer.end()
        onNoteChange?(.ended(noteID: writer.noteID, reason: reason))
    }
}

/// The Notes screens' state (ARCHITECTURE.md, "Host app", `NotesLibrary`), over a real notes directory and vault with
/// the fake key store, and the fake host. Test text is invented.
enum NotesLibraryTests {
    static var tests: [TestCase] {
        [
            ("firstUseMakesTheVaultAndOffersTheRecoveryCode", isolated(testFirstUseMakesTheVaultAndOffersTheRecoveryCode)),
            ("withoutAPasscodeNothingIsMade", isolated(testWithoutAPasscodeNothingIsMade)),
            ("aRecoveryCodeShowsUntilDoneOrLocked", isolated(testARecoveryCodeShowsUntilDoneOrLocked)),
            ("lockingLeavesNoNoteText", isolated(testLockingLeavesNoNoteText)),
            ("unlockShowsWhatWasRecordedMeanwhile", isolated(testUnlockShowsWhatWasRecordedMeanwhile)),
            ("aCancelledUnlockStaysLockedQuietly", isolated(testACancelledUnlockStaysLockedQuietly)),
            ("aLockDuringTheUnlockWins", isolated(testALockDuringTheUnlockWins)),
            ("recordOnALockedVaultStartsANewNote", isolated(testRecordOnALockedVaultStartsANewNote)),
            ("recordUnlockedOpensTheNewNote", isolated(testRecordUnlockedOpensTheNewNote)),
            ("theLiveTextFollowsPiecesAndTail", isolated(testTheLiveTextFollowsPiecesAndTail)),
            ("theTailIsAskedForOnlyWhileTheOpenNoteRecordsUnlocked", isolated(testTheTailIsAskedForOnlyWhileTheOpenNoteRecordsUnlocked)),
            ("anEndedNoteIsMergedAtOnce", isolated(testAnEndedNoteIsMergedAtOnce)),
            ("aNewNoteWithoutWordsCloses", isolated(testANewNoteWithoutWordsCloses)),
            ("editsSaveWithinTheDelay", isolated(testEditsSaveWithinTheDelay)),
            ("editsSaveBeforeALockAndOnLeaving", isolated(testEditsSaveBeforeALockAndOnLeaving)),
            ("resumeSavesThenRecordsAtTheCursor", isolated(testResumeSavesThenRecordsAtTheCursor)),
            ("searchFollowsTheQueryAndTheNotes", isolated(testSearchFollowsTheQueryAndTheNotes)),
            ("deleteClosesTheNoteAndWaitsForARecording", isolated(testDeleteClosesTheNoteAndWaitsForARecording)),
            ("eraseLeavesNoVaultAndWaitsForARecording", isolated(testEraseLeavesNoVaultAndWaitsForARecording)),
            ("theRecoveryCodeRestoresAMissingSecret", isolated(testTheRecoveryCodeRestoresAMissingSecret)),
            ("unreadableNotesAreCounted", isolated(testUnreadableNotesAreCounted)),
            ("refusedStartsSaySo", isolated(testRefusedStartsSaySo)),
            ("aLockRightAfterUnlockWins", isolated(testALockRightAfterUnlockWins)),
            ("aPasscodeSetLaterIsSeen", isolated(testAPasscodeSetLaterIsSeen)),
            ("aDraftThatCannotBeSavedStaysOpen", isolated(testADraftThatCannotBeSavedStaysOpen)),
            ("anEndingNoEditorShowsIsSaid", isolated(testAnEndingNoEditorShowsIsSaid)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// The library over a fixture, with the draft's saves held until the test runs them.
    @MainActor
    private final class Harness {
        let notes = NoteFixture()
        let host: FakeNoteHost
        var library: NotesLibrary!
        private(set) var scheduled: [@MainActor () -> Void] = []

        init(vault: Bool = true) {
            host = FakeNoteHost(notes)
            if vault { try! notes.vault.makeVault() }
            relaunch()
        }

        /// A new library and vault on the same files, as a new process: locked.
        func relaunch() {
            notes.relaunch()
            library = NotesLibrary(vault: notes.vault, host: host, format: NoteFixture.format) { [unowned self] _, work in
                scheduled.append(work)
            }
        }

        func runScheduled() {
            let work = scheduled
            scheduled = []
            for item in work { item() }
        }

        func unlock() {
            library.unlock()
            TestSupport.expect(TestSupport.waitUntil(timeout: 2) { !library.isUnlocking }, "the unlock never ended")
        }

        /// The note's text as the vault has it, read by a new process.
        func storedText(_ id: UUID) -> String {
            let reader = NoteVault(storage: NoteStorage(directory: notes.directory), keyStore: notes.keyStore,
                                   formatRun: NoteFixture.format)
            try! reader.unlock(prompt: "test")
            return try! reader.note(id).text
        }
    }

    // MARK: Vault

    @MainActor
    private static func testFirstUseMakesTheVaultAndOffersTheRecoveryCode() {
        let h = Harness(vault: false)
        TestSupport.expectEqual(h.library.screen, .firstUse)
        h.library.makeVault()
        TestSupport.expectEqual(h.library.state, .unlocked)
        TestSupport.expectEqual(h.library.screen, .recoveryOffer)
        h.library.skipRecoveryCode()
        TestSupport.expectEqual(h.library.screen, .unlocked)
        TestSupport.expect(h.library.hits.isEmpty, "a new vault lists a note")
        TestSupport.expect(!h.library.hasRecoveryCode, "skipping made a code")
    }

    @MainActor
    private static func testWithoutAPasscodeNothingIsMade() {
        let h = Harness(vault: false)
        h.notes.keyStore.deviceHasPasscode = false
        h.relaunch()
        TestSupport.expectEqual(h.library.screen, .needsPasscode)
        h.library.makeVault()
        TestSupport.expectEqual(h.library.state, .noVault)
        TestSupport.expectEqual(h.library.message, NoteError.noPasscode.message)
        TestSupport.expect(h.notes.files().isEmpty, "a vault without a passcode wrote files")
    }

    @MainActor
    private static func testARecoveryCodeShowsUntilDoneOrLocked() {
        let h = Harness(vault: false)
        h.library.makeVault()
        h.library.makeRecoveryCode()
        TestSupport.expect(h.library.recoveryCode.map { NoteRecoveryCode($0) != nil } == true, "no code shown")
        TestSupport.expectEqual(h.library.screen, .unlocked)
        TestSupport.expect(h.library.hasRecoveryCode, "the code was not made")
        h.library.doneWithRecoveryCode()
        TestSupport.expectEqual(h.library.recoveryCode, nil)
        // Replacing it shows the new one, once; a lock drops it.
        h.library.makeRecoveryCode()
        TestSupport.expect(h.library.recoveryCode != nil, "no replacement shown")
        h.library.lock()
        TestSupport.expectEqual(h.library.recoveryCode, nil)
    }

    @MainActor
    private static func testLockingLeavesNoNoteText() {
        let h = Harness()
        let id = h.notes.record(["Invented harbour inventory"])
        h.unlock()
        h.library.search("harbour")
        h.library.open(id)
        h.library.edit("Invented harbour inventory, revised")
        h.library.lock()
        TestSupport.expectEqual(h.library.state, .locked)
        TestSupport.expectEqual(h.library.screen, .locked)
        TestSupport.expect(h.library.hits.isEmpty, "the list outlived the lock")
        TestSupport.expectEqual(h.library.query, "")
        TestSupport.expectEqual(h.library.openNote, nil)
        TestSupport.expectEqual(h.library.draft, nil)
        TestSupport.expectEqual(h.library.liveText, nil)
        TestSupport.expectEqual(h.library.unreadableCount, 0)
        // Only which note is open stays.
        TestSupport.expectEqual(h.library.openNoteID, id)
        TestSupport.expectEqual(h.storedText(id), "Invented harbour inventory, revised")
    }

    @MainActor
    private static func testUnlockShowsWhatWasRecordedMeanwhile() {
        let h = Harness()
        h.unlock()
        h.library.record()
        let id = h.library.openNoteID!
        h.host.report(settled: "Quiet lanterns", provisional: "")
        h.library.lock()
        h.host.report(settled: "drift over the canal", provisional: "and")
        TestSupport.expectEqual(h.library.provisional, "")
        h.unlock()
        TestSupport.expectEqual(h.library.state, .unlocked)
        TestSupport.expectEqual(h.library.openNote?.text, "Quiet lanterns drift over the canal")
        h.host.end(.stopped)
        TestSupport.expectEqual(h.library.draft, "Quiet lanterns drift over the canal")
        TestSupport.expectEqual(h.library.openNoteID, id)
    }

    @MainActor
    private static func testACancelledUnlockStaysLockedQuietly() {
        let h = Harness()
        h.notes.keyStore.userCancels = true
        h.unlock()
        TestSupport.expectEqual(h.library.state, .locked)
        TestSupport.expectEqual(h.library.message, nil)
    }

    @MainActor
    private static func testALockDuringTheUnlockWins() {
        let h = Harness()
        h.notes.record(["Invented sentence about kites"])
        let vault = h.notes.vault
        h.notes.keyStore.whileAsking = { vault.lock() }
        h.unlock()
        TestSupport.expectEqual(h.library.state, .locked)
        TestSupport.expect(h.library.hits.isEmpty, "a lock during the unlock left notes listed")
        TestSupport.expectEqual(h.library.message, nil)
    }

    // MARK: Recording

    @MainActor
    private static func testRecordOnALockedVaultStartsANewNote() {
        let h = Harness()
        TestSupport.expectEqual(h.library.screen, .locked)
        h.library.record()
        TestSupport.expectEqual(h.host.targets, [.newNote])
        TestSupport.expect(h.host.voiceNoteID != nil, "no note started")
        TestSupport.expectEqual(h.library.state, .locked)
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expectEqual(h.library.recordingNoteID, h.host.voiceNoteID)
        h.library.stop()
        TestSupport.expectEqual(h.host.voiceNoteID, nil)
        TestSupport.expectEqual(h.library.recordingNoteID, nil)
    }

    @MainActor
    private static func testRecordUnlockedOpensTheNewNote() {
        let h = Harness()
        h.unlock()
        h.library.record()
        TestSupport.expect(h.library.openNoteID != nil, "the new note did not open")
        TestSupport.expectEqual(h.library.openNoteID, h.host.voiceNoteID)
        TestSupport.expectEqual(h.library.draft, nil)
        TestSupport.expectEqual(h.library.liveText?.before, "")
    }

    @MainActor
    private static func testTheLiveTextFollowsPiecesAndTail() {
        let h = Harness()
        h.unlock()
        h.library.record()
        h.host.report(settled: "", provisional: "Seven")
        TestSupport.expectEqual(h.library.liveText, live("", "Seven", ""))
        h.host.report(settled: "Seven violet", provisional: "kites")
        TestSupport.expectEqual(h.library.liveText, live("Seven violet", " kites", ""))
        TestSupport.expectEqual(h.library.hits.first?.note.text, "Seven violet")
        h.host.report(settled: "kites rise", provisional: "")
        TestSupport.expectEqual(h.library.liveText, live("Seven violet kites rise", "", ""))
    }

    @MainActor
    private static func testTheTailIsAskedForOnlyWhileTheOpenNoteRecordsUnlocked() {
        let h = Harness()
        let other = h.notes.record(["An older invented note"])
        h.unlock()
        TestSupport.expect(h.host.onNoteProvisional == nil, "the list asked for the tail")
        h.library.record()
        TestSupport.expect(h.host.onNoteProvisional != nil, "the recording note did not ask for its tail")
        h.library.close()
        TestSupport.expect(h.host.onNoteProvisional == nil, "a closed note still asks for the tail")
        h.library.open(other)
        TestSupport.expect(h.host.onNoteProvisional == nil, "another note asks for the tail")
        h.library.open(h.host.voiceNoteID!)
        TestSupport.expect(h.host.onNoteProvisional != nil, "reopening the recording note did not ask")
        h.library.lock()
        TestSupport.expect(h.host.onNoteProvisional == nil, "a locked vault asks for the tail")
        h.unlock()
        TestSupport.expect(h.host.onNoteProvisional != nil, "the unlock did not ask again")
        h.host.end(.stopped)
        TestSupport.expect(h.host.onNoteProvisional == nil, "an ended note asks for the tail")
    }

    @MainActor
    private static func testAnEndedNoteIsMergedAtOnce() {
        let h = Harness()
        h.unlock()
        h.library.record()
        let id = h.library.openNoteID!
        h.host.report(settled: "Copper bells", provisional: "ring")
        h.host.end(.reachedLimit)
        TestSupport.expectEqual(try! h.notes.vault.note(id).pendingRuns, [])
        TestSupport.expectEqual(h.library.draft, "Copper bells")
        TestSupport.expectEqual(h.library.provisional, "")
        TestSupport.expectEqual(h.library.openNoteEnding, .reachedLimit)
        // Ended while locked, it is merged at the next unlock.
        h.library.resume(at: .end)
        h.library.lock()
        h.host.report(settled: "at noon", provisional: "")
        h.host.end(.stopped)
        h.unlock()
        TestSupport.expectEqual(try! h.notes.vault.note(id).pendingRuns, [])
        TestSupport.expectEqual(h.library.draft, "Copper bells at noon")
        TestSupport.expectEqual(h.library.openNoteEnding, nil)
    }

    @MainActor
    private static func testANewNoteWithoutWordsCloses() {
        let h = Harness()
        h.unlock()
        h.library.record()
        TestSupport.expect(h.library.openNoteID != nil, "the new note did not open")
        h.library.stop()
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expect(h.library.hits.isEmpty, "an empty note is listed")
    }

    // MARK: Editing

    @MainActor
    private static func testEditsSaveWithinTheDelay() {
        let h = Harness()
        let id = h.notes.record(["Invented draft"])
        h.unlock()
        h.library.open(id)
        TestSupport.expectEqual(h.library.draft, "Invented draft")
        h.library.edit("Invented draft, one")
        h.library.edit("Invented draft, one more")
        TestSupport.expectEqual(h.scheduled.count, 1)
        TestSupport.expectEqual(h.storedText(id), "Invented draft")
        h.runScheduled()
        TestSupport.expectEqual(h.storedText(id), "Invented draft, one more")
        TestSupport.expectEqual(h.library.hits.first?.note.text, "Invented draft, one more")
        h.library.edit("Invented draft, again")
        TestSupport.expectEqual(h.scheduled.count, 1)
    }

    @MainActor
    private static func testEditsSaveBeforeALockAndOnLeaving() {
        let h = Harness()
        let id = h.notes.record(["Invented paragraph"])
        h.unlock()
        h.library.open(id)
        h.library.edit("Invented paragraph, closed")
        h.library.close()
        TestSupport.expectEqual(h.storedText(id), "Invented paragraph, closed")
        h.library.open(id)
        h.library.edit("Invented paragraph, locked")
        h.library.lock()
        TestSupport.expectEqual(h.storedText(id), "Invented paragraph, locked")
        h.runScheduled()   // a save due after the lock writes nothing
        TestSupport.expectEqual(h.storedText(id), "Invented paragraph, locked")
    }

    @MainActor
    private static func testResumeSavesThenRecordsAtTheCursor() {
        let h = Harness()
        let id = h.notes.record(["Alpha omega"])
        h.unlock()
        h.library.open(id)
        h.library.edit("Alpha and omega")
        h.library.resume(at: .offset(9))
        TestSupport.expectEqual(h.host.targets, [.note(id, at: .offset(9))])
        TestSupport.expectEqual(try! h.notes.vault.note(id).body, "Alpha and omega")
        TestSupport.expectEqual(h.library.draft, nil)
        h.host.report(settled: "beta", provisional: "gamma")
        TestSupport.expectEqual(h.library.liveText, live("Alpha and beta", " gamma", " omega"))
        h.host.end(.stopped)
        TestSupport.expectEqual(h.library.draft, "Alpha and beta omega")
    }

    @MainActor
    private static func testSearchFollowsTheQueryAndTheNotes() {
        let h = Harness()
        h.notes.record(["Orchard ladders lean"])
        h.notes.now += 60
        h.notes.record(["Harbour cranes"])
        h.unlock()
        TestSupport.expectEqual(h.library.hits.map(\.note.text), ["Harbour cranes", "Orchard ladders lean"])
        h.library.search("lad")
        TestSupport.expectEqual(h.library.hits.map(\.note.text), ["Orchard ladders lean"])
        TestSupport.expectEqual(h.library.hits.first?.matchedCharacters, [8 ..< 11])
        // A note that changes is searched as it now reads, and the query stays.
        h.notes.now += 60
        h.library.record()
        h.host.report(settled: "Ladders again", provisional: "")
        TestSupport.expectEqual(h.library.query, "lad")
        TestSupport.expectEqual(h.library.hits.map(\.note.text), ["Ladders again", "Orchard ladders lean"])
        h.library.search("")
        TestSupport.expectEqual(h.library.hits.count, 3)
    }

    @MainActor
    private static func testDeleteClosesTheNoteAndWaitsForARecording() {
        let h = Harness()
        let id = h.notes.record(["Invented note to delete"])
        h.unlock()
        h.library.record()
        h.host.report(settled: "Still recording", provisional: "")
        h.library.deleteOpenNote()
        TestSupport.expectEqual(h.library.message, NoteError.noteIsRecording.message)
        TestSupport.expect(h.library.openNoteID != nil, "a recording note was closed")
        h.library.dismissMessage()
        h.host.end(.stopped)
        h.library.open(id)
        h.library.deleteOpenNote()
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expectEqual(h.library.message, nil)
        TestSupport.expectEqual(h.library.hits.map(\.note.text), ["Still recording"])
    }

    @MainActor
    private static func testEraseLeavesNoVaultAndWaitsForARecording() {
        let h = Harness()
        h.notes.record(["Invented note to erase"])
        h.library.record()
        h.library.eraseAll()
        TestSupport.expectEqual(h.library.message, NoteError.noteIsRecording.message)
        TestSupport.expectEqual(h.library.state, .locked)
        h.library.stop()
        h.library.eraseAll()
        TestSupport.expectEqual(h.library.state, .noVault)
        TestSupport.expectEqual(h.library.screen, .firstUse)
    }

    @MainActor
    private static func testTheRecoveryCodeRestoresAMissingSecret() {
        let h = Harness(vault: false)
        h.library.makeVault()
        h.library.makeRecoveryCode()
        let code = h.library.recoveryCode!
        let id = h.notes.record(["Invented note kept by the code"])
        h.notes.keyStore.secret = nil
        h.relaunch()
        TestSupport.expectEqual(h.library.screen, .secretMissing)
        h.library.restore(recoveryCode: "not a code")
        TestSupport.expectEqual(h.library.message, NoteError.malformedRecoveryCode.message)
        h.library.restore(recoveryCode: String(repeating: "0", count: 32))
        TestSupport.expectEqual(h.library.message, NoteError.wrongRecoveryCode.message)
        TestSupport.expectEqual(h.library.state, .secretMissing)
        h.library.restore(recoveryCode: code.lowercased())
        TestSupport.expectEqual(h.library.state, .unlocked)
        TestSupport.expectEqual(h.library.hits.map(\.note.id), [id])
    }

    @MainActor
    private static func testUnreadableNotesAreCounted() {
        let h = Harness()
        let id = h.notes.record(["Invented note that will not open"])
        h.notes.record(["Invented note that opens"])
        h.unlock()
        h.library.lock()
        // Merged at the unlock, so the note has a body; spoil it.
        try! Data("spoiled".utf8).write(to: h.notes.noteDirectory(id).appendingPathComponent("body"))
        h.relaunch()
        h.unlock()
        TestSupport.expectEqual(h.library.unreadableCount, 1)
        TestSupport.expectEqual(h.library.hits.map(\.note.text), ["Invented note that opens"])
    }

    @MainActor
    private static func testRefusedStartsSaySo() {
        let h = Harness()
        h.host.refuse = .needsApp(.locked)
        h.library.record()
        TestSupport.expectEqual(h.library.message, NoteStartOutcome.needsApp(.locked).message)
        h.library.dismissMessage()
        TestSupport.expectEqual(h.library.message, nil)
    }

    /// A lock issued before the authentication even begins still wins.
    @MainActor
    private static func testALockRightAfterUnlockWins() {
        let h = Harness()
        h.notes.record(["Invented note behind the lock"])
        h.library.unlock()
        h.library.lock()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { !h.library.isUnlocking }, "the unlock never ended")
        TestSupport.expectEqual(h.library.state, .locked)
        TestSupport.expect(h.library.hits.isEmpty, "a lock before the unlock began left notes listed")
        TestSupport.expectEqual(h.notes.vault.state, .locked)
    }

    @MainActor
    private static func testAPasscodeSetLaterIsSeen() {
        let h = Harness(vault: false)
        h.notes.keyStore.deviceHasPasscode = false
        h.relaunch()
        TestSupport.expectEqual(h.library.screen, .needsPasscode)
        h.notes.keyStore.deviceHasPasscode = true
        h.library.refreshState()
        TestSupport.expectEqual(h.library.screen, .firstUse)
    }

    @MainActor
    private static func testADraftThatCannotBeSavedStaysOpen() {
        let h = Harness()
        let id = h.notes.record(["Invented text that stays"])
        let other = h.notes.record(["Another invented note"])
        h.unlock()
        h.library.open(id)
        h.library.edit("Invented text that stays, edited")
        var changes = 0
        h.library.onChange = { changes += 1 }
        let directory = h.notes.noteDirectory(id)
        try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        h.runScheduled()
        TestSupport.expectEqual(h.library.message, NoteError.storageFailed.message)
        TestSupport.expect(changes > 0, "a failed save was not reported")
        h.library.dismissMessage()
        h.library.close()
        h.library.open(other)
        TestSupport.expectEqual(h.library.openNoteID, id)
        TestSupport.expectEqual(h.library.draft, "Invented text that stays, edited")
        TestSupport.expectEqual(h.library.message, NoteError.storageFailed.message)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        h.library.close()
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expectEqual(h.storedText(id), "Invented text that stays, edited")
    }

    @MainActor
    private static func testAnEndingNoEditorShowsIsSaid() {
        let h = Harness()
        // Recorded from the locked screen.
        h.library.record()
        h.host.report(settled: "Invented words", provisional: "")
        h.host.end(.interrupted)
        TestSupport.expectEqual(h.library.message, NoteEndReason.interrupted.message)
        h.library.dismissMessage()
        // Open, but it ends before any words, so the note goes and its editor with it.
        h.unlock()
        h.library.record()
        h.host.end(.captureFailed)
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expectEqual(h.library.message, NoteEndReason.captureFailed.message)
        h.library.dismissMessage()
        // The open editor says it itself; a stop says nothing.
        h.library.record()
        h.host.report(settled: "More invented words", provisional: "")
        h.host.end(.reachedLimit)
        TestSupport.expectEqual(h.library.openNoteEnding, .reachedLimit)
        TestSupport.expectEqual(h.library.message, nil)
        h.library.resume(at: .end)
        h.host.end(.stopped)
        TestSupport.expectEqual(h.library.message, nil)
        // Open, locked, and ended before any words: the unlock finds it gone, and Notes says why.
        h.library.close()
        h.library.record()
        h.library.lock()
        h.host.end(.interrupted)
        h.unlock()
        TestSupport.expectEqual(h.library.openNoteID, nil)
        TestSupport.expectEqual(h.library.message, NoteEndReason.interrupted.message)
    }

    private static func live(_ before: String, _ provisional: String, _ after: String) -> NoteLiveText {
        var text = NoteLiveText(note: Note(id: UUID(), text: "", body: "", created: Fixture.now, modified: Fixture.now,
                                           pendingRuns: []), provisional: "", format: NoteFixture.format)
        text.before = before
        text.provisional = provisional
        text.after = after
        return text
    }
}

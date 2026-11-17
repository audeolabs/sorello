import Foundation

/// Runs (ARCHITECTURE.md, "Notes", Runs, Storage and Library and search): recording with the public key alone, a
/// run's place, reading a note while it records, merging, a crash at any step, and the unlocked side's edits.
/// Every text is invented.
enum NoteRunTests {
    static var tests: [TestCase] {
        [
            ("recordingNeedsOnlyThePublicKey", testRecordingNeedsOnlyThePublicKey),
            ("recordingIntoAGoneNoteFails", testRecordingIntoAGoneNoteFails),
            ("emptyPiecesWriteNothingAndAnEndedRunTakesNoMore", testEmptyPiecesWriteNothingAndAnEndedRunTakesNoMore),
            ("aRunMergesAtItsPlace", testARunMergesAtItsPlace),
            ("placesAreClampedToCharacterBoundaries", testPlacesAreClampedToCharacterBoundaries),
            ("runsMergeInOrder", testRunsMergeInOrder),
            ("aRunWaitsForTheRecordingRunBeforeIt", testARunWaitsForTheRecordingRunBeforeIt),
            ("aNoteShowsItsRecordingRunAndMergesItOnlyOnceEnded", testANoteShowsItsRecordingRunAndMergesItOnlyOnceEnded),
            ("aMergeSurvivesACrashBetweenAnyTwoSteps", testAMergeSurvivesACrashBetweenAnyTwoSteps),
            ("aRunCutShortByACrashIsMergedAtTheNextUnlock", testARunCutShortByACrashIsMergedAtTheNextUnlock),
            ("aRunWithoutItsStartGoesAtTheEnd", testARunWithoutItsStartGoesAtTheEnd),
            ("aRunWithAnUnreadableFileWaits", testARunWithAnUnreadableFileWaits),
            ("leftoversAreRemovedAtUnlock", testLeftoversAreRemovedAtUnlock),
            ("movedRecordsDoNotOpen", testMovedRecordsDoNotOpen),
            ("aNewNoteWithNoTextIsRemoved", testANewNoteWithNoTextIsRemoved),
            ("anUnreadableBodyIsLeftAlone", testAnUnreadableBodyIsLeftAlone),
            ("replacingTextReplacesPendingRuns", testReplacingTextReplacesPendingRuns),
            ("aRecordingNoteCannotBeEditedOrDeleted", testARecordingNoteCannotBeEditedOrDeleted),
            ("deletingANoteRemovesIt", testDeletingANoteRemovesIt),
            ("notesAreNewestFirst", testNotesAreNewestFirst),
        ]
    }

    /// A vault made and locked, as when a recording starts on a locked iPhone.
    private static func lockedFixture() -> NoteFixture {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.vault.lock()
        fixture.relaunch()
        return fixture
    }

    /// A note holding `text` alone, merged, with the vault unlocked.
    private static func note(_ text: String, in fixture: NoteFixture) -> UUID {
        if fixture.vault.state != .unlocked { fixture.unlock() }
        let id = fixture.record(["placeholder"])
        try! fixture.vault.mergePendingRuns()
        try! fixture.vault.replaceText(of: id, with: text)
        return id
    }

    private static func testRecordingNeedsOnlyThePublicKey() {
        let fixture = lockedFixture()
        // A recorder over the storage alone: no key store, no vault.
        let recorder = NoteRecorder(storage: NoteStorage(directory: fixture.directory), now: { Fixture.now })
        let writer = try! recorder.beginRun(.newNote)
        try! writer.append("Invented first sentence.")
        try! writer.append("And an invented second.")
        writer.end()
        for (name, data) in fixture.files() {
            TestSupport.expect(!noteBytes(data, contain: "Invented first") && !noteBytes(data, contain: "invented second"),
                               "\(name) holds the run's text")
        }
        TestSupport.expectEqual(fixture.vault.state, .locked)
        fixture.unlock()
        let notes = try! fixture.vault.notes()
        TestSupport.expectEqual(notes.map(\.id), [writer.noteID])
        TestSupport.expectEqual(notes.map(\.text), ["Invented first sentence. And an invented second."])
        TestSupport.expectEqual(notes.map(\.created), [Fixture.now])
    }

    private static func testRecordingIntoAGoneNoteFails() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        TestSupport.expectEqual(Result { try fixture.recorder.beginRun(.note(UUID(), at: .end)) }.noteError, .noSuchNote)
        let id = note("Invented", in: fixture)
        try! fixture.vault.deleteNote(id)
        TestSupport.expectEqual(Result { try fixture.recorder.beginRun(.note(id, at: .end)) }.noteError, .noSuchNote)
        TestSupport.expectEqual(try! fixture.vault.notes(), [])
    }

    private static func testEmptyPiecesWriteNothingAndAnEndedRunTakesNoMore() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let writer = try! fixture.recorder.beginRun(.newNote)
        try! writer.append("")
        try! writer.append("Invented")
        try! writer.append("")
        TestSupport.expectEqual(try! fixture.vault.note(writer.noteID).pendingRuns.map(\.pieces), [["Invented"]])
        writer.end()
        TestSupport.expectEqual(Result { try writer.append("Late") }.noteError, .runEnded)
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented"])
    }

    private static func testARunMergesAtItsPlace() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Buy apples and pears.", in: fixture)
        fixture.vault.lock()
        // After "Buy apples" (UTF-16 offset 10), recorded with the vault locked.
        fixture.record(["plums"], into: .note(id, at: .offset(10)))
        fixture.record(["Then invented errands."], into: .note(id, at: .end))
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Buy apples plums and pears. Then invented errands."])
        TestSupport.expectEqual(try! fixture.vault.note(id).body, "Buy apples plums and pears. Then invented errands.")
        TestSupport.expectEqual(try! fixture.vault.note(id).pendingRuns, [])
        TestSupport.expectEqual(fixture.runDirectories(of: id), [])
    }

    private static func testPlacesAreClampedToCharacterBoundaries() {
        let text = "a😀e\u{301}b"   // UTF-16: a, two for the emoji, e, the combining accent, b
        func merged(_ place: NoteRunPlace) -> String {
            NoteMerge.merge([NoteRunContent(place: place, pieces: ["X"])], into: text) { pieces, _, _ in pieces.joined() }
        }
        TestSupport.expectEqual(merged(.offset(-4)), "Xa😀e\u{301}b")
        TestSupport.expectEqual(merged(.offset(0)), "Xa😀e\u{301}b")
        TestSupport.expectEqual(merged(.offset(1)), "aX😀e\u{301}b")
        TestSupport.expectEqual(merged(.offset(2)), "aX😀e\u{301}b")   // inside the emoji
        TestSupport.expectEqual(merged(.offset(3)), "a😀Xe\u{301}b")
        TestSupport.expectEqual(merged(.offset(4)), "a😀Xe\u{301}b")   // inside the accented e
        TestSupport.expectEqual(merged(.offset(5)), "a😀e\u{301}Xb")
        TestSupport.expectEqual(merged(.offset(6)), "a😀e\u{301}bX")
        TestSupport.expectEqual(merged(.offset(60)), "a😀e\u{301}bX")
        TestSupport.expectEqual(merged(.end), "a😀e\u{301}bX")
        // The formatter sees the text around the place.
        var seen: [String] = []
        _ = NoteMerge.merge([NoteRunContent(place: .offset(3), pieces: ["X"])], into: text) { _, before, after in
            seen = [String(before), String(after)]
            return ""
        }
        TestSupport.expectEqual(seen, ["a😀", "e\u{301}b"])
    }

    private static func testRunsMergeInOrder() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("One three", in: fixture)
        fixture.vault.lock()
        fixture.record(["two"], into: .note(id, at: .offset(3)))
        // The second run's place is in the text the first made: "One two three", after "two".
        fixture.record(["and a half"], into: .note(id, at: .offset(7)))
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["One two and a half three"])
    }

    private static func testARunWaitsForTheRecordingRunBeforeIt() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented.", in: fixture)
        let first = try! fixture.recorder.beginRun(.note(id, at: .end))
        try! first.append("First.")
        fixture.record(["Second."], into: .note(id, at: .end))
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! fixture.vault.note(id).body, "Invented.")
        TestSupport.expectEqual(try! fixture.vault.note(id).text, "Invented. First. Second.")
        first.end()
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! fixture.vault.note(id).body, "Invented. First. Second.")
    }

    private static func testANoteShowsItsRecordingRunAndMergesItOnlyOnceEnded() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented start.", in: fixture)
        fixture.now = Fixture.now.addingTimeInterval(60)
        let writer = try! fixture.recorder.beginRun(.note(id, at: .end))
        try! writer.append("First piece.")
        try! writer.append("Second piece.")
        var shown = try! fixture.vault.note(id)
        TestSupport.expect(shown.isRecording, "the note does not say it records")
        TestSupport.expectEqual(shown.body, "Invented start.")
        TestSupport.expectEqual(shown.text, "Invented start. First piece. Second piece.")
        TestSupport.expectEqual(shown.pendingRuns.map(\.pieces), [["First piece.", "Second piece."]])
        TestSupport.expectEqual(shown.modified, Fixture.now.addingTimeInterval(60))
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! fixture.vault.note(id).body, "Invented start.")
        TestSupport.expectEqual(fixture.runDirectories(of: id).count, 1)
        try! writer.append("Third.")
        writer.end()
        try! fixture.vault.mergePendingRuns()
        shown = try! fixture.vault.note(id)
        TestSupport.expect(!shown.isRecording, "the note still records")
        TestSupport.expectEqual(shown.body, "Invented start. First piece. Second piece. Third.")
        TestSupport.expectEqual(shown.pendingRuns, [])
        TestSupport.expectEqual(fixture.runDirectories(of: id), [])
    }

    /// The steps of a merge are: the body is replaced, then the run's files are removed one by one. A crash after
    /// any of them leaves the body and some of the run's files; a crash before the first leaves both as they were.
    /// Each of those states, opened by a new process, ends with the run merged exactly once.
    private static func testAMergeSurvivesACrashBetweenAnyTwoSteps() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented opening.", in: fixture)
        fixture.vault.lock()
        fixture.record(["One.", "Two.", "Three."], into: .note(id, at: .end))
        let before = copy(fixture.noteDirectory(id), into: fixture.root)
        let runName = fixture.runDirectories(of: id)[0].lastPathComponent
        let runFiles = try! FileManager.default.contentsOfDirectory(atPath: before.appendingPathComponent(runName).path).sorted()
        fixture.unlock()
        let expected = "Invented opening. One. Two. Three."
        TestSupport.expectEqual(fixture.noteTexts(), [expected])
        let after = copy(fixture.noteDirectory(id), into: fixture.root)

        // Before the body was replaced.
        restore(before, to: fixture.noteDirectory(id))
        fixture.relaunch()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), [expected])
        TestSupport.expectEqual(fixture.runDirectories(of: id), [])

        // After the body was replaced, with any number of the run's files still there, in any order of removal.
        for kept in 0 ... runFiles.count {
            for rotation in 0 ..< max(runFiles.count, 1) {
                restore(after, to: fixture.noteDirectory(id))
                let runDirectory = fixture.noteDirectory(id).appendingPathComponent(runName, isDirectory: true)
                try! FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                let rotated = Array(runFiles[rotation...] + runFiles[..<rotation])
                for name in rotated.prefix(kept) {
                    try! FileManager.default.copyItem(at: before.appendingPathComponent(runName).appendingPathComponent(name),
                                                      to: runDirectory.appendingPathComponent(name))
                }
                fixture.relaunch()
                fixture.unlock()
                TestSupport.expectEqual(fixture.noteTexts(), [expected])
                TestSupport.expectEqual(fixture.runDirectories(of: id), [])
            }
        }
    }

    private static func testARunCutShortByACrashIsMergedAtTheNextUnlock() {
        let fixture = lockedFixture()
        let writer = try! fixture.recorder.beginRun(.newNote)
        try! writer.append("Words before the invented crash.")
        // The process dies: the run is never ended, and a write was cut short before its rename.
        let staging = fixture.runDirectories(of: writer.noteID)[0].appendingPathComponent(".staging-\(UUID().uuidString).tmp")
        try! Data("sealed bytes".utf8).write(to: staging)
        fixture.relaunch()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Words before the invented crash."])
        TestSupport.expectEqual(fixture.runDirectories(of: writer.noteID), [])
        TestSupport.expect(!FileManager.default.fileExists(atPath: staging.path), "the staging file survived")
        withExtendedLifetime(writer) {}
    }

    private static func testARunWithoutItsStartGoesAtTheEnd() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented body.", in: fixture)
        fixture.vault.lock()
        fixture.record(["Tail."], into: .note(id, at: .offset(0)))
        try! FileManager.default.removeItem(at: fixture.runDirectories(of: id)[0].appendingPathComponent("start"))
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented body. Tail."])
    }

    /// A file that cannot be read now, as a class B file while the iPhone is locked, here made unreadable by its
    /// permissions.
    private static func testARunWithAnUnreadableFileWaits() {
        let fixture = lockedFixture()
        let id = fixture.record(["Alpha.", "Beta."])
        let segment = fixture.runDirectories(of: id)[0].appendingPathComponent("segment-1")
        try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment.path) }
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Beta."])
        TestSupport.expectEqual(fixture.runDirectories(of: id).count, 1)
        try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment.path)
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! fixture.vault.note(id).body, "Alpha. Beta.")
        TestSupport.expectEqual(fixture.runDirectories(of: id), [])
    }

    private static func testLeftoversAreRemovedAtUnlock() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented.", in: fixture)
        fixture.vault.lock()
        let leftovers = [
            fixture.directory.appendingPathComponent(".staging-\(UUID().uuidString).tmp"),
            fixture.noteDirectory(id).appendingPathComponent(".staging-\(UUID().uuidString).tmp"),
        ]
        for url in leftovers { try! Data("sealed bytes".utf8).write(to: url) }
        let deleted = fixture.directory.appendingPathComponent(".deleted-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        try! Data("sealed bytes".utf8).write(to: deleted.appendingPathComponent("body"))
        fixture.unlock()
        for url in leftovers + [deleted] {
            TestSupport.expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) survived")
        }
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented."])
    }

    private static func testMovedRecordsDoNotOpen() {
        let fixture = lockedFixture()
        let first = fixture.record(["Alpha.", "Beta.", "Gamma."])
        let second = fixture.record(["Delta."])
        let firstRun = fixture.runDirectories(of: first)[0]
        let secondRun = fixture.runDirectories(of: second)[0]
        // Swap the first run's first two segments, and copy the second note's segment in as the first run's fourth.
        let one = firstRun.appendingPathComponent("segment-1"), two = firstRun.appendingPathComponent("segment-2")
        let swap = firstRun.appendingPathComponent("swap")
        try! FileManager.default.moveItem(at: one, to: swap)
        try! FileManager.default.moveItem(at: two, to: one)
        try! FileManager.default.moveItem(at: swap, to: two)
        try! FileManager.default.copyItem(at: secondRun.appendingPathComponent("segment-1"),
                                          to: firstRun.appendingPathComponent("segment-4"))
        fixture.unlock()
        TestSupport.expectEqual(try! fixture.vault.note(first).text, "Gamma.")
        TestSupport.expectEqual(try! fixture.vault.note(second).text, "Delta.")
    }

    private static func testANewNoteWithNoTextIsRemoved() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let writer = try! fixture.recorder.beginRun(.newNote)
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.text), [""])
        writer.end()
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! fixture.vault.notes(), [])
        TestSupport.expect(!FileManager.default.fileExists(atPath: fixture.noteDirectory(writer.noteID).path),
                           "the empty note's directory survived")
    }

    private static func testAnUnreadableBodyIsLeftAlone() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented.", in: fixture)
        let other = note("Another invented note.", in: fixture)
        fixture.vault.lock()
        let body = fixture.noteDirectory(id).appendingPathComponent("body")
        var damaged = try! Data(contentsOf: body)
        damaged[damaged.count - 1] ^= 0x01
        try! damaged.write(to: body)
        fixture.record(["More."], into: .note(id, at: .end))
        fixture.unlock()
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.id), [other])
        TestSupport.expectEqual(try! fixture.vault.unreadableNoteCount(), 1)
        TestSupport.expectEqual(Result { try fixture.vault.note(id) }.noteError, .noSuchNote)
        TestSupport.expectEqual(Result { try fixture.vault.replaceText(of: id, with: "Over") }.noteError, .noSuchNote)
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(try! Data(contentsOf: body), damaged)
        TestSupport.expectEqual(fixture.runDirectories(of: id).count, 1)
    }

    private static func testReplacingTextReplacesPendingRuns() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented draft.", in: fixture)
        fixture.record(["Shown before the edit."], into: .note(id, at: .end))
        TestSupport.expectEqual(try! fixture.vault.note(id).text, "Invented draft. Shown before the edit.")
        fixture.now = Fixture.now.addingTimeInterval(120)
        try! fixture.vault.replaceText(of: id, with: "Invented final text.")
        let edited = try! fixture.vault.note(id)
        TestSupport.expectEqual(edited.text, "Invented final text.")
        TestSupport.expectEqual(edited.pendingRuns, [])
        TestSupport.expectEqual(edited.created, Fixture.now)
        TestSupport.expectEqual(edited.modified, Fixture.now.addingTimeInterval(120))
        fixture.vault.lock()
        fixture.relaunch()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented final text."])
    }

    private static func testARecordingNoteCannotBeEditedOrDeleted() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = note("Invented.", in: fixture)
        let writer = try! fixture.recorder.beginRun(.note(id, at: .end))
        TestSupport.expectEqual(Result { try fixture.vault.replaceText(of: id, with: "Changed") }.noteError, .noteIsRecording)
        TestSupport.expectEqual(Result { try fixture.vault.deleteNote(id) }.noteError, .noteIsRecording)
        writer.end()
        try! fixture.vault.deleteNote(id)
        TestSupport.expectEqual(try! fixture.vault.notes(), [])
    }

    private static func testDeletingANoteRemovesIt() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let kept = note("Kept invented note.", in: fixture)
        let gone = note("Deleted invented note.", in: fixture)
        try! fixture.vault.deleteNote(gone)
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.id), [kept])
        TestSupport.expectEqual(Result { try fixture.vault.deleteNote(gone) }.noteError, .noSuchNote)
        TestSupport.expect(!fixture.files().keys.contains { $0.contains(gone.uuidString) }, "the note's files survived")
        fixture.relaunch()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Kept invented note."])
    }

    private static func testNotesAreNewestFirst() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let old = note("Oldest.", in: fixture)
        fixture.now = Fixture.now.addingTimeInterval(10)
        let middle = note("Middle.", in: fixture)
        fixture.now = Fixture.now.addingTimeInterval(20)
        let new = note("Newest.", in: fixture)
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.id), [new, middle, old])
        // An edit, or a run, makes a note newer.
        fixture.now = Fixture.now.addingTimeInterval(30)
        try! fixture.vault.replaceText(of: old, with: "Oldest, edited.")
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.id), [old, new, middle])
        fixture.now = Fixture.now.addingTimeInterval(40)
        fixture.record(["More."], into: .note(middle, at: .end))
        TestSupport.expectEqual(try! fixture.vault.notes().map(\.id), [middle, old, new])
    }

    private static func copy(_ directory: URL, into root: URL) -> URL {
        let copy = root.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.copyItem(at: directory, to: copy)
        return copy
    }

    private static func restore(_ copy: URL, to directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        try! FileManager.default.copyItem(at: copy, to: directory)
    }
}

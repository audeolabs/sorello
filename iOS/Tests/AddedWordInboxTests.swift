import DictionaryKit
import Foundation

/// ARCHITECTURE.md, "Custom dictionary", Words from corrections, and "Files", One added word: `AddedWordInbox` over a
/// real store and library and the fake transcriber's correction calls, then through the session core. All words are
/// invented.
enum AddedWordInboxTests {
    static var tests: [TestCase] {
        [
            ("refusesWhatTheDictionaryCannotTake", isolated(testRefusesWhatTheDictionaryCannotTake)),
            ("aKeyAlreadyThereChangesNothing", isolated(testAKeyAlreadyThereChangesNothing)),
            ("aHeardWordIsSavedAtTheStrengthFound", isolated(testAHeardWordIsSavedAtTheStrengthFound)),
            ("aWordNotHeardIsNotSaved", isolated(testAWordNotHeardIsNotSaved)),
            ("anUndecidedCheckSavesAtOne", isolated(testAnUndecidedCheckSavesAtOne)),
            ("withoutItsDictationTheWordIsSavedAtOne", isolated(testWithoutItsDictationTheWordIsSavedAtOne)),
            ("aRangeThatDoesNotFitIsSavedAtOne", isolated(testARangeThatDoesNotFitIsSavedAtOne)),
            ("aKeyAddedDuringTheCheckIsNeverChanged", isolated(testAKeyAddedDuringTheCheckIsNeverChanged)),
            ("aFullDictionaryDuringTheCheckSavesNothing", isolated(testAFullDictionaryDuringTheCheckSavesNothing)),
            ("theTakenCopyIsDecidedAndWordsWaitTheirTurn", isolated(testTheTakenCopyIsDecidedAndWordsWaitTheirTurn)),
            ("staleAndMalformedCopiesAreIgnored", isolated(testStaleAndMalformedCopiesAreIgnored)),
            ("anUnreadableCopyIsHeldUntilReadOrExpired", isolated(testAnUnreadableCopyIsHeldUntilReadOrExpired)),
            ("theOutcomeExpires", isolated(testTheOutcomeExpires)),
            ("theKeptTextGoesWithTheEnginesCopy", isolated(testTheKeptTextGoesWithTheEnginesCopy)),
            ("theCoreKeepsTheNewestDictation", isolated(testTheCoreKeepsTheNewestDictation)),
            ("theCoreReleasesOnEveryEvent", isolated(testTheCoreReleasesOnEveryEvent)),
            ("theSignalDecidesAndTheStatusPublishes", isolated(testTheSignalDecidesAndTheStatusPublishes)),
            ("aDiscardedResultReleasesItsAudio", isolated(testADiscardedResultReleasesItsAudio)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    private static let R = Fixture.requestID
    private static let S = Fixture.otherRequestID
    private static let otherWordID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!

    /// Every letter as its own piece, so any invented word of letters is encodable; "#" is not.
    static let encoder: BPEEncoder = {
        var pieces = ["<unk>", "▁"]
        pieces += "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars.map { String($0) }
        return BPEEncoder(pieces: pieces)
    }()

    @MainActor
    final class Harness {
        let directory = TestSupport.makeTemporaryDirectory()
        let suite = "SorelloIOSTests-\(UUID().uuidString)"
        let store: SharedDictationStore
        let defaults: UserDefaults
        let library: DictionaryLibrary
        let transcriber = FakeTranscriber()
        final class Clock {
            var now = Fixture.now
            var uptime: TimeInterval = 1_000
        }
        private let clock = Clock()
        var now: Date {
            get { clock.now }
            set { clock.now = newValue }
        }
        var uptime: TimeInterval {
            get { clock.uptime }
            set { clock.uptime = newValue }
        }
        let inbox: AddedWordInbox
        var outcomes = 0

        init(encoder: BPEEncoder? = AddedWordInboxTests.encoder, entries: [DictionaryEntry] = []) {
            store = SharedDictationStore(directory: directory)
            defaults = UserDefaults(suiteName: suite)!
            if !entries.isEmpty { DictionaryStorage.save(CustomDictionary(entries: entries, ignore: [])!, to: defaults) }
            library = DictionaryLibrary(defaults: defaults, encoder: encoder)
            let clock = self.clock
            inbox = AddedWordInbox(store: store, library: library, verifier: transcriber, now: { clock.now },
                                   uptime: { clock.uptime })
            inbox.onOutcome = { [unowned self] in self.outcomes += 1 }
        }

        func cleanup() {
            transcriber.answerVerifications(.unverified)
            _ = TestSupport.waitUntil(timeout: 0.05) { false }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        /// Writes `word` as the keyboard does, takes it, and waits until it is decided.
        @discardableResult
        func add(_ word: AddedWord) -> AddedWordStatus? {
            try! store.writeAddedWord(word)
            inbox.take()
            _ = TestSupport.waitUntil(timeout: 2) { self.inbox.outcome?.id == word.id && !self.inbox.isDeciding }
            return inbox.outcome?.id == word.id ? inbox.outcome : nil
        }

        func entry(_ key: String) -> DictionaryEntry? { library.entries.first { $0.key == DictionaryKey(key) } }

        var fileNames: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
        var stagingNames: [String] { fileNames.filter { $0.hasPrefix(SharedDictationStore.stagingPrefix) } }
    }

    private static func word(_ text: String = "Xylo", for requestID: UUID = R, range: Range<Int> = 1..<2,
                             id: UUID = Fixture.addedWordID, at issuedAt: Date = Fixture.now) -> AddedWord {
        Fixture.addedWord(text, requestID: requestID, range: range, id: id, issuedAt: issuedAt)
    }

    private static func outcome(_ value: AddedWordStatus.Outcome, strength: Float? = nil,
                                id: UUID = Fixture.addedWordID) -> AddedWordStatus {
        AddedWordStatus(id: id, outcome: value, strength: strength, decidedAt: Fixture.now)
    }

    /// Letters only, so every one is a valid, distinct entry.
    private static func letters(_ index: Int) -> String {
        var value = index, text = ""
        repeat {
            text.append(Character(Unicode.Scalar(UInt8(97 + value % 26))))
            value /= 26
        } while value > 0
        return "q" + text
    }

    // MARK: Decision

    /// Step 1: no vocabulary, a full dictionary or an invalid word is `notAdded`, before any check.
    @MainActor
    private static func testRefusesWhatTheDictionaryCannotTake() {
        let none = Harness(encoder: nil)
        defer { none.cleanup() }
        none.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        TestSupport.expectEqual(none.add(word()), outcome(.notAdded))

        let full = Harness(entries: (0..<DictionaryValidation.capacity).map { DictionaryEntry(text: letters($0), strength: 1) })
        defer { full.cleanup() }
        full.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        TestSupport.expectEqual(full.add(word()), outcome(.notAdded))

        let invalid = Harness()
        defer { invalid.cleanup() }
        invalid.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        TestSupport.expectEqual(invalid.add(word("C#")), outcome(.notAdded))
        for harness in [none, full, invalid] {
            TestSupport.expectEqual(harness.transcriber.verifications.count, 0)
            TestSupport.expect(harness.entry("xylo") == nil, "saved a word the dictionary could not take")
        }
    }

    /// Step 2: the key is there: nothing changes, nothing is checked.
    @MainActor
    private static func testAKeyAlreadyThereChangesNothing() {
        let h = Harness(entries: [DictionaryEntry(text: "xylo", strength: 4)])
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        TestSupport.expectEqual(h.add(word("Xylo")), outcome(.alreadyInDictionary))
        TestSupport.expectEqual(h.entry("xylo"), DictionaryEntry(text: "xylo", strength: 4))
        TestSupport.expectEqual(h.transcriber.verifications.count, 0)
    }

    /// Step 3: its own dictation is kept; the edited text is rebuilt from the text written, and the strength found is
    /// saved. Only that dictation is released.
    @MainActor
    private static func testAHeardWordIsSavedAtTheStrengthFound() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "Call zylo now.")
        h.transcriber.verification = .verified(DictionarySuggestion(word: "Xylo", strength: 2.83, kind: .replace))
        TestSupport.expectEqual(h.add(word("Xylo", range: 1..<2)), outcome(.added, strength: 2.83))
        TestSupport.expectEqual(h.entry("xylo"), DictionaryEntry(text: "Xylo", strength: 2.83))
        let check = h.transcriber.verifications.first
        TestSupport.expectEqual(check?.typed, "Call zylo now.")
        TestSupport.expectEqual(check?.edited, "Call Xylo now.")
        TestSupport.expectEqual(check?.correctionID, 7)
        TestSupport.expectEqual(h.transcriber.correctionLog, ["verify 7", "release 7"])
        TestSupport.expectEqual(h.inbox.kept, nil)
        TestSupport.expectEqual(h.outcomes, 1)
    }

    @MainActor
    private static func testAWordNotHeardIsNotSaved() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.transcriber.verification = .notRecognized
        TestSupport.expectEqual(h.add(word()), outcome(.notHeard))
        TestSupport.expect(h.entry("xylo") == nil, "saved a word that was not heard")
        TestSupport.expectEqual(h.transcriber.correctionLog, ["verify 7", "release 7"])
    }

    /// Step 4: a check that decided nothing saves at ×1.
    @MainActor
    private static func testAnUndecidedCheckSavesAtOne() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.transcriber.verification = .unverified
        TestSupport.expectEqual(h.add(word()), outcome(.added, strength: 1))
        TestSupport.expectEqual(h.entry("xylo")?.strength, 1)
    }

    /// Step 4 without a check: nothing kept, or another dictation kept, which a decided word never releases.
    @MainActor
    private static func testWithoutItsDictationTheWordIsSavedAtOne() {
        let h = Harness()
        defer { h.cleanup() }
        TestSupport.expectEqual(h.add(word("Xylo")), outcome(.added, strength: 1))
        // The word corrects R, but S (recorded since) is kept.
        h.inbox.keep(requestID: S, correctionID: 9, text: "a newer dictation")
        TestSupport.expectEqual(h.add(word("Quint", id: otherWordID)), outcome(.added, strength: 1, id: otherWordID))
        TestSupport.expectEqual(h.transcriber.verifications.count, 0)
        TestSupport.expectEqual(h.transcriber.correctionLog, [])
        TestSupport.expectEqual(h.inbox.kept?.correctionID, 9)
    }

    /// The range is judged against the kept text: past its words, or more than three words (punctuation-only pieces
    /// do not count), is step 4; the dictation is still its own and is released.
    @MainActor
    private static func testARangeThatDoesNotFitIsSavedAtOne() {
        for (index, range) in [3..<5, 1..<5].enumerated() {
            let h = Harness()
            defer { h.cleanup() }
            h.inbox.keep(requestID: R, correctionID: 7, text: index == 0 ? "a b c" : "a b c d e f")
            TestSupport.expectEqual(h.add(word(range: range)), outcome(.added, strength: 1))
            TestSupport.expectEqual(h.transcriber.correctionLog, ["release 7"])
            TestSupport.expectEqual(h.inbox.kept, nil)
        }
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "send it — to sam now")
        h.transcriber.verification = .verified(DictionarySuggestion(word: "Xylo", strength: 2, kind: .replace))
        TestSupport.expectEqual(h.add(word(range: 1..<5)), outcome(.added, strength: 2))
        TestSupport.expectEqual(h.transcriber.verifications.first?.edited, "send Xylo now")
    }

    /// The save is decided again after the check: a key the user added meanwhile is never replaced.
    @MainActor
    private static func testAKeyAddedDuringTheCheckIsNeverChanged() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.transcriber.holdsVerification = true
        try! h.store.writeAddedWord(word())
        h.inbox.take()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.waitingVerifications == 1 }, "no check")
        TestSupport.expectEqual(h.library.save(text: "XYLO", strength: 5.66, replacing: nil), nil)
        h.transcriber.answerVerifications(.verified(DictionarySuggestion(word: "Xylo", strength: 2, kind: .replace)))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.inbox.outcome != nil }, "not decided")
        TestSupport.expectEqual(h.inbox.outcome, outcome(.alreadyInDictionary))
        TestSupport.expectEqual(h.entry("xylo"), DictionaryEntry(text: "XYLO", strength: 5.66))
    }

    @MainActor
    private static func testAFullDictionaryDuringTheCheckSavesNothing() {
        let h = Harness(entries: (0..<(DictionaryValidation.capacity - 1)).map { DictionaryEntry(text: letters($0), strength: 1) })
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.transcriber.holdsVerification = true
        try! h.store.writeAddedWord(word())
        h.inbox.take()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.waitingVerifications == 1 }, "no check")
        TestSupport.expectEqual(h.library.save(text: "Zorblax", strength: 1, replacing: nil), nil)
        h.transcriber.answerVerifications(.verified(DictionarySuggestion(word: "Xylo", strength: 2, kind: .replace)))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.inbox.outcome != nil }, "not decided")
        TestSupport.expectEqual(h.inbox.outcome, outcome(.notAdded))
        TestSupport.expect(h.entry("xylo") == nil, "saved into a full dictionary")
    }

    // MARK: Take

    /// What is decided is the copy taken; a word written after it waits in the file for the next take, and a word
    /// taken while another is decided waits for it.
    @MainActor
    private static func testTheTakenCopyIsDecidedAndWordsWaitTheirTurn() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.transcriber.holdsVerification = true
        try! h.store.writeAddedWord(word("Xylo"))
        h.inbox.take()
        let replacement = word("Quint", for: S, id: otherWordID)
        try! h.store.writeAddedWord(replacement)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.waitingVerifications == 1 }, "no check")
        TestSupport.expectEqual(h.transcriber.verifications.first?.edited, "call Xylo now")
        TestSupport.expectEqual(h.store.readAddedWord(), .value(replacement))
        h.inbox.take()
        TestSupport.expectEqual(h.store.readAddedWord(), .absent)
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.inbox.outcome, nil)
        h.transcriber.answerVerifications(.verified(DictionarySuggestion(word: "Xylo", strength: 2, kind: .replace)))
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.inbox.outcome?.id == otherWordID }, "second not decided")
        TestSupport.expectEqual(h.outcomes, 2)
        TestSupport.expectEqual(h.entry("xylo")?.strength, 2)
        TestSupport.expectEqual(h.entry("quint")?.strength, 1)
        TestSupport.expectEqual(h.fileNames, [])
    }

    @MainActor
    private static func testStaleAndMalformedCopiesAreIgnored() {
        let h = Harness()
        defer { h.cleanup() }
        var other = word()
        other.schema = 2
        var backwards = word()
        backwards.replacedStart = 3
        backwards.replacedEnd = 1
        let ignored = [word(at: Fixture.now - DictationProtocol.addedWordTTL - 1),
                       word(at: Fixture.now + DictationProtocol.clockSkewTolerance + 1),
                       word("   "), word(range: 2..<2), backwards, word(range: -1..<1), other]
        for record in ignored {
            try! h.store.writeAddedWord(record)
            h.inbox.take()
            TestSupport.expectEqual(h.fileNames, [])
        }
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(h.inbox.outcome, nil)
        TestSupport.expectEqual(h.library.entries, [])
        // At the boundary it is still fresh.
        TestSupport.expectEqual(h.add(word(at: Fixture.now - DictationProtocol.addedWordTTL)), outcome(.added, strength: 1))
    }

    /// A copy that cannot be read yet (the device is locked) stays under its private name and is read at the next take,
    /// until `addedWordTTL` after its modification date. While it waits, a newer file is left where it is.
    @MainActor
    private static func testAnUnreadableCopyIsHeldUntilReadOrExpired() {
        let h = Harness()
        defer { h.cleanup() }
        h.now = Date()
        try! FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try! Data("{".utf8).write(to: h.store.addedWordURL)
        h.inbox.take()
        TestSupport.expectEqual(h.store.readAddedWord(), .absent)
        TestSupport.expectEqual(h.stagingNames.count, 1)
        let held = h.directory.appendingPathComponent(h.stagingNames[0])
        try! h.store.writeAddedWord(word("Quint", id: otherWordID, at: h.now))
        h.inbox.take()
        TestSupport.expectEqual(h.store.readAddedWord().value?.id, otherWordID)
        // "Unlocked": the held copy reads now and is decided; the newer file is taken after it.
        try! FileManager.default.removeItem(at: h.store.addedWordURL)
        try! h.store.writeAddedWord(word("Xylo", at: h.now))
        TestSupport.expectEqual(rename(h.store.addedWordURL.path, held.path), 0)
        try! h.store.writeAddedWord(word("Quint", id: otherWordID, at: h.now))
        h.inbox.take()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.inbox.outcome?.id == otherWordID }, "not decided")
        TestSupport.expect(h.entry("xylo") != nil && h.entry("quint") != nil, "a word was lost")
        TestSupport.expectEqual(h.fileNames, [])

        // Never readable: deleted unread once its file is past the TTL.
        try! Data("{".utf8).write(to: h.store.addedWordURL)
        h.inbox.take()
        TestSupport.expectEqual(h.stagingNames.count, 1)
        let stale = h.directory.appendingPathComponent(h.stagingNames[0])
        try! FileManager.default.setAttributes([.modificationDate: h.now - DictationProtocol.addedWordTTL - 1],
                                               ofItemAtPath: stale.path)
        h.inbox.take()
        TestSupport.expectEqual(h.fileNames, [])
    }

    @MainActor
    private static func testTheOutcomeExpires() {
        let h = Harness()
        defer { h.cleanup() }
        TestSupport.expectEqual(h.add(word())?.outcome, .added)
        TestSupport.expectEqual(h.inbox.status(now: Fixture.now + DictationProtocol.addedWordTTL)?.id, Fixture.addedWordID)
        TestSupport.expectEqual(h.inbox.status(now: Fixture.now + DictationProtocol.addedWordTTL + 1), nil)
    }

    /// What is kept goes when the engine lets it go (90 s of uptime), on the core's tick, without any other event; a
    /// newer dictation's record is timed from its own keep, and no wall-clock change stretches it.
    @MainActor
    private static func testTheKeptTextGoesWithTheEnginesCopy() {
        let h = Harness()
        defer { h.cleanup() }
        h.inbox.keep(requestID: R, correctionID: 7, text: "call zylo now")
        h.uptime += 60
        h.inbox.keep(requestID: S, correctionID: 8, text: "a newer dictation")
        h.uptime += 30
        h.inbox.expire()
        TestSupport.expectEqual(h.inbox.kept?.correctionID, 8)
        h.now -= 30   // the wall clock went back
        h.uptime += AddedWordInbox.keptLifetime - 30
        h.inbox.expire()
        TestSupport.expectEqual(h.inbox.kept, nil)
        // A word that arrives after that is saved without a check.
        h.inbox.keep(requestID: R, correctionID: 9, text: "call zylo now")
        h.uptime += AddedWordInbox.keptLifetime
        TestSupport.expectEqual(h.add(word(at: h.now))?.strength, 1)
        TestSupport.expectEqual(h.transcriber.verifications.count, 0)

        let (core, words) = coreHarness()
        defer { core.cleanup(); words.cleanup() }
        core.core.userStartSession()
        core.addedWords!.keep(requestID: R, correctionID: 7, text: "call zylo now")
        core.core.tick()
        TestSupport.expectEqual(core.addedWords?.kept?.correctionID, 7)
        core.uptime += AddedWordInbox.keptLifetime
        core.keepCaptureFresh()
        core.core.tick()
        TestSupport.expectEqual(core.addedWords?.kept, nil)
    }

    // MARK: Through the session core

    @MainActor
    private static func coreHarness() -> (CoreHarness, Harness) {
        let words = Harness()
        let h = CoreHarness(dictionary: words.library)
        h.transcriber.streams = true
        return (h, words)
    }

    /// Records, finishes and transcribes `requestID`, its stream keeping `correctionID`.
    @MainActor
    private static func dictate(_ h: CoreHarness, _ requestID: UUID, correctionID: UInt64?, text: String = "call zylo now") {
        h.record(requestID)
        h.writeIntent(.finish, requestID)
        h.core.reconcile(.intentSignal)
        h.completeTail()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }, "transcription not started")
        h.transcriber.complete(.success(text), correctionID: correctionID)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.core.current?.phase == .completed }, "not completed")
    }

    /// The text written to the result is kept with the correction id; a new recording releases it before its own
    /// stream opens.
    @MainActor
    private static func testTheCoreKeepsTheNewestDictation() {
        let (h, words) = coreHarness()
        defer { h.cleanup(); words.cleanup() }
        dictate(h, R, correctionID: 7)
        TestSupport.expectEqual(h.addedWords?.kept,
                                AddedWordInbox.Kept(requestID: R, correctionID: 7, text: "<call zylo now>"))
        h.clock.now += 1
        dictate(h, S, correctionID: nil)
        TestSupport.expectEqual(h.addedWords?.kept, nil)
        let log = h.transcriber.correctionLog
        TestSupport.expectEqual(Array(log.suffix(2)), ["discard", "stream"])
    }

    @MainActor
    private static func testTheCoreReleasesOnEveryEvent() {
        let (h, words) = coreHarness()
        defer { h.cleanup(); words.cleanup() }
        let inbox = h.addedWords!
        h.core.userStartSession()
        func kept() { inbox.keep(requestID: R, correctionID: 7, text: "call zylo now") }
        kept()
        h.core.dictionaryEdited()
        TestSupport.expectEqual(inbox.kept, nil)
        kept()
        h.core.deviceWillLock()
        TestSupport.expectEqual(inbox.kept, nil)
        h.core.deviceDidUnlock()
        kept()
        h.core.userEndSession()
        TestSupport.expectEqual(inbox.kept, nil)
        kept()
        h.transcriber.modelState = .notPrepared
        h.core.modelStateChanged()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { inbox.kept == nil }, "the runtime's release kept it")
        TestSupport.expectEqual(h.transcriber.correctionLog.filter { $0 == "discard" }.count, 4)
    }

    /// `.addedWord` takes the word; its outcome is published in the status, which names no word, and goes after the
    /// TTL.
    @MainActor
    private static func testTheSignalDecidesAndTheStatusPublishes() {
        let (h, words) = coreHarness()
        defer { h.cleanup(); words.cleanup() }
        dictate(h, R, correctionID: 7)
        h.transcriber.verification = .verified(DictionarySuggestion(word: "Xylo", strength: 2, kind: .replace))
        try! h.store.writeAddedWord(word("Xylo", at: h.clock.now))
        h.core.addedWordSignal()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.status?.addedWord != nil }, "no outcome published")
        TestSupport.expectEqual(h.status?.addedWord?.outcome, .added)
        TestSupport.expectEqual(h.status?.addedWord?.strength, 2)
        TestSupport.expectEqual(h.status?.addedWord?.id, Fixture.addedWordID)
        TestSupport.expectEqual(h.transcriber.verifications.first?.typed, "<call zylo now>")
        TestSupport.expectEqual(words.entry("xylo")?.strength, 2)
        h.clock.now += DictationProtocol.addedWordTTL + 1
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expectEqual(h.status?.addedWord, nil)
        // The heartbeat takes a word too.
        try! h.store.writeAddedWord(word("Quint", id: otherWordID, at: h.clock.now))
        h.clock.now += 1
        h.keepCaptureFresh()
        h.core.tick()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.status?.addedWord?.id == otherWordID }, "heartbeat")
    }

    /// A result discarded because a newer recording superseded it releases what its stream kept.
    @MainActor
    private static func testADiscardedResultReleasesItsAudio() {
        let (h, words) = coreHarness()
        defer { h.cleanup(); words.cleanup() }
        h.transcriber.honorsCancellation = false
        h.record(R)
        h.writeIntent(.finish, R)
        h.core.reconcile(.intentSignal)
        h.completeTail()
        _ = TestSupport.waitUntil(timeout: 2) { h.transcriber.pendingCount == 1 }
        h.writeIntent(.record, S)
        h.core.reconcile(.intentSignal)
        h.transcriber.complete(.success("late words"), correctionID: 9)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { h.transcriber.correctionLog.contains("release 9") },
                           "the late result's audio was not released")
        TestSupport.expectEqual(h.addedWords?.kept, nil)
    }
}

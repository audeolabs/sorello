@testable import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Persistence
import SorelloUI
import Synchronization
import Testing
@testable import SorelloApp

/// A watch that the test drives: it binds anchors by generation as the real one does, and records what it was asked.
final class FakeWatcher: CorrectionWatching {
    private struct State {
        var generation: UInt64 = 0
        var started: [(pasted: String, correctionID: UInt64, generation: UInt64)] = []
        var cancels = 0
    }

    private let state = Mutex(State())

    var currentGeneration: UInt64 { state.withLock { $0.generation } }
    var started: [(pasted: String, correctionID: UInt64, generation: UInt64)] { state.withLock { $0.started } }
    var cancels: Int { state.withLock { $0.cancels } }

    func anchor(_ field: PreparedField, expecting expected: UInt64) -> WatchAnchor? {
        state.withLock { state in
            guard state.generation == expected else { return nil }
            state.generation += 1
            return WatchAnchor(generation: state.generation, value: field.selection.location)
        }
    }

    func start(_ anchor: WatchAnchor, pasted: String, correctionID: UInt64) {
        state.withLock { $0.started.append((pasted, correctionID, anchor.generation)) }
    }

    func cancel() {
        state.withLock { state in
            state.generation += 1
            state.cancels += 1
        }
    }

    func claim(_ watch: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == watch else { return false }
            state.generation += 1
            return true
        }
    }
}

/// A coordinator over a real dictionary in a temporary file and fakes for everything else.
@MainActor
final class CorrectionHarness {
    let watcher = FakeWatcher()
    let speech = FakeSpeech()
    let clock = ManualClock()
    let settings: SettingsStore
    let dictionary: DictionaryLibrary
    var session = SessionState()
    var holdIsDown = false
    var trusted = true
    private(set) var onEdit: (@MainActor @Sendable (CorrectionEdit, Bool, UInt64) -> Void)?
    private(set) var onAbandon: (@MainActor @Sendable () -> Void)?
    var coordinator: CorrectionCoordinator!

    init(directory: URL, defaults: UserDefaults) throws {
        settings = SettingsStore(defaults: defaults)
        let model = try makeModelDirectory(in: directory)
        let encoder = try BPEEncoder(vocabularyFile: model.appendingPathComponent("vocabulary.json"))
        dictionary = DictionaryLibrary(
            store: DictionaryStore(fileURL: directory.appendingPathComponent("dictionary.json"), encoder: encoder),
            encoder: encoder)
        coordinator = CorrectionCoordinator(
            settings: settings, dictionary: dictionary, engine: speech, clock: clock,
            inputs: .init(session: { [unowned self] in session }, holdIsDown: { [unowned self] in holdIsDown },
                          accessibilityTrusted: { [unowned self] in trusted }),
            makeWatcher: { [unowned self] edit, abandon in
                onEdit = edit
                onAbandon = abandon
                return watcher
            })
        dictionary.didChange = { [unowned self] in coordinator.dictionaryChanged() }
    }

    static let field = DestinationField(PreparedField(target: TextFieldTarget(pid: 42, element: "field"),
                                                      selection: TextFieldRange(location: 6, length: 0)))

    /// Starts dictation `id` into `app`, inserts `text` to a readable field, and reports it inserted.
    func dictate(_ id: UInt64, text: String = "Meet Okonquo at noon.", app: AppIdentity? = nil,
                 destination: InsertionDestination = .cursor(context: nil, field: CorrectionHarness.field),
                 outcome: InsertionOutcome = .inserted, usedMacro: Bool = false, pressEnter: Bool = false,
                 correctionID: UInt64? = 77) {
        let dictation = DictationID(id)
        coordinator.dictationStarted(dictation, app: app)
        coordinator.willInsert(dictation, destination: destination)
        coordinator.dictationCompleted(DictationCompletion(
            id: dictation, ending: .insertion(outcome), speech: SpeechResult(text: text, correctionID: correctionID),
            processed: ProcessedDictation(heard: text, text: text, pressEnter: pressEnter, usedMacro: usedMacro)))
    }

    /// The watch reports an edit and the engine finds `word`.
    func edit(finding word: String?, isLast: Bool = false) async {
        speech.suggestion = word.map { DictionarySuggestion(word: $0, strength: 2, kind: .replace) }
        onEdit?(CorrectionEdit(typed: "Okonquo", edited: "Okonkwo", correctionID: 77), isLast,
                watcher.currentGeneration)
    }
}

@MainActor
@Suite struct CorrectionCoordinatorTests {
    @Test func anInsertedDictationIntoAReadableFieldIsWatched() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        #expect(harness.watcher.started.map(\.pasted) == ["Meet Okonquo at noon."])
        #expect(harness.watcher.started.map(\.correctionID) == [77])
        #expect(harness.speech.released.isEmpty)
    }

    @Test func everyOtherEndingReleasesTheAudio() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1, usedMacro: true)
        harness.dictate(2, pressEnter: true)
        harness.dictate(3, destination: .clipboard(.accessibilityMissing), outcome: .leftOnClipboard(.accessibilityMissing))
        harness.dictate(4, destination: .cursor(context: nil, field: nil))
        harness.dictate(5, outcome: .failed(.eventPostFailed))
        harness.dictate(6, text: "")
        #expect(harness.watcher.started.isEmpty)
        #expect(harness.speech.released == [77, 77, 77, 77, 77, 77])

        // Nothing kept, nothing to release.
        harness.dictate(7, correctionID: nil)
        #expect(harness.speech.released.count == 6)

        harness.settings.correctionSuggestions = false
        harness.dictate(8)
        #expect(harness.watcher.started.isEmpty)
        #expect(harness.speech.released.count == 7)
    }

    @Test func aRecordingThatStartsBeforeTheInsertionVoidsTheWatch() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        let first = DictationID(1)
        harness.coordinator.dictationStarted(first, app: nil)
        // A second dictation starts while the first is still being transcribed.
        harness.coordinator.dictationStarted(DictationID(2), app: nil)
        harness.coordinator.willInsert(first, destination: .cursor(context: nil, field: CorrectionHarness.field))
        harness.coordinator.dictationCompleted(DictationCompletion(
            id: first, ending: .insertion(.inserted), speech: SpeechResult(text: "Hello there.", correctionID: 77),
            processed: ProcessedDictation(heard: "Hello there.", text: "Hello there.")))
        #expect(harness.watcher.started.isEmpty)
        #expect(harness.speech.released == [77])
        #expect(harness.watcher.cancels == 2)
    }

    @Test func aDictionaryChangeAfterTheRecordingStartedVoidsTheWatch() throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        let dictation = DictationID(1)
        harness.coordinator.dictationStarted(dictation, app: nil)
        try harness.dictionary.save(text: "Quillon", strength: 1, apps: [], replacing: nil)
        #expect(harness.speech.discards == 1)
        harness.coordinator.willInsert(dictation, destination: .cursor(context: nil, field: CorrectionHarness.field))
        harness.coordinator.dictationCompleted(DictationCompletion(
            id: dictation, ending: .insertion(.inserted), speech: SpeechResult(text: "Hello there.", correctionID: 77),
            processed: ProcessedDictation(heard: "Hello there.", text: "Hello there.")))
        #expect(harness.watcher.started.isEmpty)
    }

    @Test func aSuggestionIntoAnAppOffersFourActionsAndAddsForThatApp() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1, app: AppIdentity(bundleID: "com.example.fieldnotes", name: "Field Notes"))
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        let notice = try #require(harness.coordinator.notice)
        #expect(notice.text == CorrectionCoordinator.question("Okonkwo"))
        #expect(notice.tone == .information)
        #expect(notice.actions.map(\.id) == ["add", "add-everywhere", "not-now", "dont-suggest"])
        #expect(notice.actions.first?.title.contains("Field Notes") == true)
        #expect(notice.actions.first?.isPrimary == true)
        #expect(AppNoticeID.isAppNotice(notice.id))
        // Claiming ended the watch, so its audio is released.
        #expect(harness.speech.released == [77])

        harness.coordinator.noticeAction(notice.id, action: "add")
        #expect(harness.coordinator.notice == nil)
        let key = DictionaryKey("Okonkwo")
        #expect(harness.dictionary.dictionary.dictionary.entries.map(\.text) == ["Okonkwo"])
        #expect(harness.dictionary.dictionary.dictionary.entries.first?.strength == 2)
        #expect(harness.dictionary.dictionary.scopes.apps(for: key) == ["com.example.fieldnotes"])
        // A second click on the same notice does nothing.
        harness.coordinator.noticeAction(notice.id, action: "add-everywhere")
        #expect(harness.dictionary.dictionary.scopes.apps(for: key) == ["com.example.fieldnotes"])
    }

    @Test func withoutAnAppThreeActionsAndDontSuggestIgnoresTheWord() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        let notice = try #require(harness.coordinator.notice)
        #expect(notice.actions.map(\.id) == ["add", "not-now", "dont-suggest"])
        harness.coordinator.noticeAction(notice.id, action: "dont-suggest")
        #expect(harness.dictionary.ignoredKeys == [DictionaryKey("Okonkwo")])
        #expect(harness.dictionary.dictionary.dictionary.entries.isEmpty)
    }

    @Test func aSuggestionLeavesAsNotNowAfterTwelveSeconds() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        await eventually { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: 11.9)
        #expect(harness.coordinator.notice != nil)
        harness.clock.advance(by: 0.2)
        await eventually { harness.coordinator.notice == nil }
        #expect(harness.dictionary.dictionary.dictionary.entries.isEmpty)
    }

    @Test func nothingIsShownWhileADictationIsUnderWay() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        harness.holdIsDown = true
        await harness.edit(finding: "Okonkwo")
        #expect(harness.speech.checks == 0)
        harness.holdIsDown = false
        harness.trusted = false
        await harness.edit(finding: "Okonkwo")
        #expect(harness.speech.checks == 0)

        // A press after the check began voids its presentation.
        harness.trusted = true
        await harness.edit(finding: "Okonkwo")
        harness.coordinator.triggerArrived(.holdPressed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.notice == nil)
    }

    @Test func aRecordingPressWithdrawsTheSuggestionAndTheSessionPreemptsIt() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        harness.coordinator.triggerArrived(.pasteAgainPressed)
        #expect(harness.coordinator.notice != nil)
        harness.coordinator.triggerArrived(.togglePressed)
        #expect(harness.coordinator.notice == nil)

        harness.dictate(2)
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        let id = try #require(harness.coordinator.notice?.id)
        harness.coordinator.preempt()
        #expect(harness.coordinator.notice == nil)
        harness.coordinator.noticeAction(id, action: "add")
        #expect(harness.dictionary.dictionary.dictionary.entries.isEmpty)
    }

    @Test func aWordThatAlreadyAppliesIsNotSuggested() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        try harness.dictionary.save(text: "Okonkwo", strength: 1, apps: [], replacing: nil)
        harness.dictate(1)
        await harness.edit(finding: "Okonkwo")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.notice == nil)
    }

    @Test func turningSuggestionsOffOrQuittingStopsEverything() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        await harness.edit(finding: "Okonkwo")
        await eventually { harness.coordinator.notice != nil }
        harness.coordinator.suggestionsTurnedOff()
        #expect(harness.coordinator.notice == nil)
        #expect(harness.speech.discards == 1)
        let cancels = harness.watcher.cancels
        harness.coordinator.quitting()
        #expect(harness.watcher.cancels == cancels + 1)
        #expect(harness.speech.discards == 2)
        harness.coordinator.runLogCleared()
        #expect(harness.speech.discards == 3)
    }

    @Test func aLastEditWithNothingToCheckReleasesTheAudio() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        harness.trusted = false
        await harness.edit(finding: nil, isLast: true)
        #expect(harness.speech.released == [77])
    }

    @Test func aWatchThatEndsQuietlyLetsItsAudioGo() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        #expect(harness.watcher.started.count == 1)
        await eventually { harness.clock.sleeperCount == 1 }
        harness.clock.advance(by: CorrectionCoordinator.watchLimit - 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.speech.released.isEmpty)
        harness.clock.advance(by: 1.1)
        await eventually { harness.speech.released == [77] }
    }

    @Test func clearingTheRunLogStopsACheckAboutToShowASuggestion() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = try CorrectionHarness(directory: directory.url, defaults: suite.defaults)
        harness.dictate(1)
        let cancels = harness.watcher.cancels
        await harness.edit(finding: "Okonkwo")
        #expect(harness.speech.checks == 1)
        // The check's result has not been delivered yet.
        harness.coordinator.runLogCleared()
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.notice == nil)
        #expect(harness.watcher.cancels == cancels + 1)
        #expect(harness.speech.discards == 1)
    }
}


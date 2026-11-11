import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Persistence
import SorelloUI
import SpeechEngine
import Testing
import TextRules
@testable import SorelloApp

/// A keyboard layout that types nothing, so only fixed key names appear.
private struct NoLayout: KeyboardLayout {
    func characters(forKeyCode code: UInt16) -> String? { nil }
}

@MainActor
@Suite struct TextRulesSnapshotTests {
    @Test func appliesTheRulesTheSettingsAndMacrosSay() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.pressEnterCommand = true
        settings.promptTag = "[spoken]"
        let macro = VoiceMacro(command: "sign off", text: "Best wishes, Ada")
        let rules = TextRulesSnapshot(settings: settings, macros: [macro])

        let expected = DictationRules.process("twenty three paper cranes press enter", options: rules.options,
                                              promptStyle: true, before: "Fold ", after: nil)
        let processed = rules.process("twenty three paper cranes press enter", style: .prompt,
                                      context: InsertionContext(before: "Fold ", after: nil))
        #expect(processed == ProcessedDictation(heard: expected.heard, text: expected.text,
                                                pressEnter: expected.pressEnter, usedMacro: expected.usedMacro,
                                                addedPromptTag: expected.addedPromptTag))
        #expect(processed.pressEnter)
        #expect(processed.text.contains("23"))

        let signed = rules.process("Sign off.", style: .plain, context: nil)
        #expect(signed.text == "Best wishes, Ada")
        #expect(signed.usedMacro)
        #expect(signed.heard == "Sign off.")
    }

    @Test func aSnapshotIgnoresLaterEdits() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        let rules = TextRulesSnapshot(settings: settings, macros: [])
        settings.spokenNumbers = false
        settings.pressEnterCommand = true
        let processed = rules.process("twenty four lanterns press enter", style: .plain, context: nil)
        #expect(processed.text.contains("24"))
        #expect(!processed.pressEnter)
    }
}

@MainActor
@Suite struct SessionSettingsTests {
    @Test func copiesWhatTheSessionReads() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.doubleTap = .prompt
        settings.restoreClipboard = false
        settings.microphoneID = "mic-7"
        let session = SessionSettings(settings: settings, dictionaryEditable: true, accessibilityTrusted: true)
        #expect(session == SessionSettings(doubleTap: .prompt, restoreClipboard: false, microphoneID: "mic-7",
                                           retainForCorrection: true))
    }

    @Test func carriesTheDoubleTapAsStored() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        #expect(SessionSettings(settings: settings, dictionaryEditable: true, accessibilityTrusted: true).doubleTap
            == .handsFree)
        for action in DoubleTapAction.allCases {
            settings.doubleTap = action
            #expect(SessionSettings(settings: settings, dictionaryEditable: true, accessibilityTrusted: true)
                .doubleTap == action)
        }
    }

    @Test func keepsAudioOnlyWhenASuggestionCouldFollow() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        #expect(!SessionSettings(settings: settings, dictionaryEditable: false, accessibilityTrusted: true)
            .retainForCorrection)
        #expect(!SessionSettings(settings: settings, dictionaryEditable: true, accessibilityTrusted: false)
            .retainForCorrection)
        settings.correctionSuggestions = false
        #expect(!SessionSettings(settings: settings, dictionaryEditable: true, accessibilityTrusted: true)
            .retainForCorrection)
    }
}

@MainActor
@Suite struct LevelFeedSinkTests {
    @Test func followsTheNewestDictation() {
        let feed = LevelFeed()
        let sink = LevelFeedSink(feed: feed)
        let loud = [Float](repeating: 0.5, count: 1600)
        sink.heard(loud, at: 1, dictation: DictationID(2))
        sink.heard(loud, at: 1.1, dictation: DictationID(1))
        #expect(feed.level(at: 1.1).capture == 2)
        sink.captureEnded(dictation: DictationID(2))
        #expect(feed.level(at: 1.1).level == 0)
    }
}

@MainActor
@Suite struct PillMappingTests {
    @Test func showsWhatTheSessionShows() {
        #expect(PillDisplay(DictationCore.PillContent.hidden) == .hidden)
        let live = ListeningPill(id: DictationID(4), mode: .toggle, style: .prompt, since: 12.5)
        #expect(PillDisplay(.listening(live)) == .listening(.init(trigger: .toggle, promptStyle: true, started: 12.5)))
        let held = ListeningPill(id: DictationID(5), mode: .hold, style: .plain, since: 3)
        #expect(PillDisplay(.listening(held)) == .listening(.init(trigger: .hold, promptStyle: false, started: 3)))
        #expect(PillDisplay(.waiting(preparingModel: true)) == .waiting(.preparingModel))
        #expect(PillDisplay(.waiting(preparingModel: false)) == .waiting(.transcribing))
    }

    @Test func aNoticeKeepsItsIdWordsAndTone() {
        let error = Notice(id: NoticeID(9), message: .microphoneDenied)
        guard case .notice(let shown) = PillDisplay(.notice(error)) else {
            Issue.record("Not a notice")
            return
        }
        #expect(shown.id == 9)
        #expect(shown.text == NoticeMessage.microphoneDenied.text)
        #expect(shown.tone == .error)
        #expect(shown.actions.isEmpty)
        #expect(!AppNoticeID.isAppNotice(shown.id))

        guard case .notice(let quiet) = PillDisplay(.notice(Notice(id: NoticeID(10), message: .nothingHeard))) else {
            Issue.record("Not a notice")
            return
        }
        #expect(quiet.tone == .information)
    }

    @Test func everyMessageHasASymbol() {
        let messages: [NoticeMessage] = [
            .busy, .microphoneDenied, .engineFailed(.modelMissing), .engineFailed(.modelCorrupt),
            .engineFailed(.loadFailed), .microphoneUnavailable, .nothingHeard, .transcriptionFailed,
            .leftOnClipboard(.accessibilityMissing), .leftOnClipboard(.targetChanged),
            .leftOnClipboard(.modifiersStillDown), .leftOnClipboard(.screenLocked),
            .insertionFailed(.commandNotPosted), .insertionFailed(.eventPostFailed),
        ]
        for message in messages { #expect(!message.symbol.isEmpty) }
        #expect(NoticeMessage.insertionFailed(.commandNotPosted).symbol == "return")
    }

    @Test func appNoticesHaveTheirOwnRange() {
        var ids = AppNoticeID()
        let first = ids.make(), second = ids.make()
        #expect(first != second)
        #expect(AppNoticeID.isAppNotice(first) && AppNoticeID.isAppNotice(second))
        #expect(!AppNoticeID.isAppNotice(UInt64(UInt32.max)))
    }
}

@MainActor
@Suite struct ShortcutMappingTests {
    let formatter = ShortcutFormatter(layout: NoLayout())

    @Test func modifierKeysNameTheirSide() {
        #expect(KeyCombo(.function, formatter: formatter) == .function)
        let combo = KeyCombo(.modifiers([.rightOption]), formatter: formatter)
        #expect(combo.modifiers == [.option(.right)])
        #expect(combo.key == nil)
        #expect(combo.inlineLabel == "Right ⌥")
    }

    @Test func aKeyBindingShowsItsModifiersAndKey() {
        let combo = KeyCombo(.key(code: 49, modifiers: [.option, .control]), formatter: formatter)
        #expect(combo.modifiers == [.control(.either), .option(.either)])
        #expect(combo.key?.label == formatter.keyName(49))
        #expect(combo.inlineLabel == "⌃⌥" + formatter.keyName(49))
    }

    @Test func settingsGiveTheMonitorEveryBoundAction() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        #expect(settings.shortcutBindings == [.holdToTalk: .function])
        settings.pasteAgainShortcut = .key(code: 9, modifiers: [.command, .shift])
        #expect(settings.shortcutBindings == [.holdToTalk: .function,
                                              .pasteAgain: .key(code: 9, modifiers: [.command, .shift])])
        #expect(Set(KeyCombo.all(settings.shortcutBindings, formatter: formatter).keys) == [.holdToTalk, .pasteAgain])
    }

    @Test func refusalsNameTheOtherAction() {
        #expect(ShortcutRefusal(.empty) == .empty)
        #expect(ShortcutRefusal(.escape) == .escape)
        #expect(ShortcutRefusal(.typingKey) == .typingKey)
        #expect(ShortcutRefusal(.usedBy(.tapToToggle)) == .alreadyUsed(by: .tapToToggle))
        for kind in ShortcutKind.allCases { #expect(ShortcutKind(kind.action) == kind) }
    }
}

@MainActor
@Suite struct StatusMappingTests {
    @Test func theEngineAndPermissionsAsTheWindowsShowThem() {
        #expect(ModelStatus(.preparing) == .preparing)
        #expect(ModelStatus(.ready) == .ready)
        #expect(ModelStatus(.failed(.modelMissing)) == .notDownloaded(.unavailable), "A copy with nothing to download")
        let size: Int64 = 138_084_519
        #expect(ModelStatus(.failed(.modelMissing), download: .absent, size: size)
                == .notDownloaded(.notStarted(size: size)))
        #expect(ModelStatus(.failed(.modelMissing), download: .downloading(received: 7), size: size)
                == .notDownloaded(.downloading(received: 7, size: size)))
        for (failure, problem) in [(ModelDownloadFailure.connection, ModelDownloadProblem.connection),
                                   (.server, .server), (.check, .check), (.disk, .disk)] {
            #expect(ModelStatus(.failed(.modelMissing), download: .failed(failure), size: size)
                    == .notDownloaded(.failed(problem, size: size)))
        }
        #expect(ModelStatus(.failed(.modelMissing), download: .unavailable, size: 0) == .notDownloaded(.unavailable))
        #expect(ModelStatus(.failed(.modelMissing), download: .installed, size: size) == .preparing,
                "The model has arrived and the engine is about to look for it")
        #expect(ModelStatus(.ready, download: .absent, size: size) == .ready, "The engine's own state wins")
        #expect(ModelStatus(.failed(.loadFailed), download: .installed, size: size) == .failed(.couldNotLoad))
        #expect(ModelStatus(.failed(.modelCorrupt)) == .failed(.damaged))
        #expect(ModelStatus(.failed(.loadFailed)) == .failed(.couldNotLoad))
        #expect(MicrophoneStatus(.unknown) == .notDetermined)
        #expect(MicrophoneStatus(.denied) == .denied)

        let status = AppStatus(session: SessionState(), accessibilityTrusted: false, shortcuts: .pausedBySecureInput)
        #expect(status == AppStatus(model: .preparing, microphone: .notDetermined, accessibility: .missing,
                                    shortcutsPaused: true))
    }

    @Test func refusedEditsInTheScreensWords() {
        #expect(DictionaryProblem(DictionaryChangeError.noVocabulary) == .needsModel)
        #expect(DictionaryProblem(DictionaryChangeError.full) == .full(capacity: DictionaryValidation.capacity))
        #expect(DictionaryProblem(DictionaryChangeError.invalid(.tooManyWords))
                == .tooManyWords(limit: DictionaryValidation.maxWords))
        #expect(DictionaryProblem(DictionaryChangeError.appsFull) == .appsFull(capacity: DictionaryAppScopes.appCapacity))
        #expect(DictionaryProblem(DictionaryChangeError.notSaved) == .notSaved)
        #expect(MacroProblem(MacroStoreError.emptyCommand) == .emptyPhrase)
        #expect(MacroProblem(MacroStoreError.duplicateCommand) == .duplicatePhrase)
        #expect(MacroProblem(MacroStoreError.saveFailed) == .notSaved)
    }
}

import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Persistence
import SorelloUI
import SpeechEngine
import Testing
@testable import SorelloApp

/// The whole graph, built against temporary directories and fake platform adapters, with a dictation run through it
/// from the shortcut to the Run Log.
@MainActor
@Suite struct CompositionTests {
    @Test func aDictationGoesFromTheShortcutToTheCursorAndTheRunLog() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults,
                              model: try makeModelDirectory(in: directory.url))
        let app = harness.app
        app.start()
        #expect(harness.shortcuts.handler === app.relay)
        #expect(harness.shortcuts.starts == 1)
        await eventually { app.runtime.state.engine == .ready }

        await harness.dictate()
        await eventually { harness.inserter.composed.count == 1 }
        let expected = TextRulesSnapshot(settings: app.settings, macros: []).process("hello world", style: .plain,
                                                                                    context: nil)
        #expect(harness.inserter.composed == [ComposedInsertion(text: expected.text, pressEnter: false)])
        // The app in front was read once, for the dictionary's per-app words, and audio was kept for a suggestion.
        #expect(harness.speech.opened == [SpeechStreamOptions(appBundleID: "com.example.fieldnotes",
                                                              retainForCorrection: true)])

        await eventually { app.history.entries.count == 1 }
        #expect(app.history.entries.first?.heard == "hello world")
        #expect(app.history.entries.first?.text == expected.text)
        await eventually { harness.windows.main.runLog.items.count == 1 }
        #expect(harness.windows.menu.lastDictation == expected.text)

        // The pill listened, waited for the words, and went away.
        await eventually { harness.pill.current == .hidden && harness.pill.shown.count >= 3 }
        #expect(harness.pill.shown.contains { if case .listening(let live) = $0 { live.trigger == .hold } else { false } })
        #expect(harness.pill.shown.contains { if case .waiting = $0 { true } else { false } })
        // Not eligible for a suggestion: the fake destination named no field, so the audio was let go.
        await eventually { harness.speech.released == [77] }
    }

    @Test func clearingTheRunLogForgetsTheLastDictationAndItsAudio() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let app = harness.app
        app.start()
        await eventually { app.runtime.state.engine == .ready }
        await harness.dictate()
        await eventually { app.history.entries.count == 1 && app.runtime.state.lastText != nil }

        harness.windows.main.runLog.actions.clearAll()
        await eventually { app.history.entries.isEmpty }
        #expect(app.runtime.state.lastText == nil)
        #expect(harness.speech.discards == 1)
        await eventually { harness.windows.menu.lastDictation == nil && harness.windows.main.runLog.items.isEmpty }
    }

    /// General says where the engine runs the model, as the engine chose it from the hardware.
    @Test(arguments: [(SpeechCompute.neuralEngine, ModelHardware.neuralEngine), (.cpu, .processor)])
    func generalSaysWhereTheModelRuns(compute: SpeechCompute, hardware: ModelHardware) throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults, compute: compute)
        #expect(harness.windows.main.general.hardware == hardware)
    }

    @Test func theWindowsShowTheRealStoresAndChangeThem() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let app = harness.app, windows = harness.windows
        app.start()

        // General's switches write the settings, and launch at login shows what the system says.
        windows.main.general.actions.setToggle(.spokenDelimiters, true)
        #expect(app.settings.spokenDelimiters)
        windows.main.general.actions.setToggle(.launchAtLogin, true)
        await eventually { windows.main.general.isOn(.launchAtLogin) }
        #expect(windows.main.general.microphones == [MicrophoneOption(id: "built-in", name: "Desk Microphone")])
        #expect(windows.main.general.defaultMicrophoneName == "Desk Microphone")

        // Macros are validated as the store would, saved, and shown.
        #expect(windows.main.macros.actions.validate("  ", "", nil) == .emptyPhrase)
        #expect(windows.main.macros.actions.save(nil, "sign off", "Warm regards") == nil)
        await eventually { windows.main.macros.macros.map(\.phrase) == ["sign off"] }
        #expect(windows.main.macros.actions.validate("Sign off!", "", nil) == .duplicatePhrase)
        let id = try #require(windows.main.macros.macros.first?.id)
        #expect(windows.main.macros.actions.validate("sign off", "", id) == nil)
        #expect(windows.main.macros.actions.save(nil, "Sign off", "Again") == .duplicatePhrase)

        // Without the model's vocabulary the dictionary cannot be edited, and says why.
        #expect(!windows.main.dictionary.canEdit)
        #expect(windows.main.dictionary.actions.validate("Okonkwo") == .needsModel)
        #expect(windows.main.dictionary.actions.add("Okonkwo", 1, []) == .needsModel)

        // The menu's commands reach the shell and the clipboard closure, never the pasteboard itself.
        var opened: [MainSection?] = []
        app.navigation.openMain = { opened.append($0) }
        windows.menu.actions.openDictionary()
        windows.menu.actions.openSettings()
        windows.menu.actions.openShortcuts()
        windows.menu.actions.openGeneral()
        windows.menu.actions.openRunLog()
        #expect(opened == [.dictionary, nil, .shortcuts, .general, .runLog])
    }

    @Test func shortcutsAreRecordedValidatedAndHandedToTheMonitor() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let app = harness.app, shortcuts = harness.windows.main.shortcuts
        app.start()

        shortcuts.recorderActions.record(.tapToToggle)
        await eventually { harness.shortcuts.isRecording && shortcuts.recorder(.tapToToggle).isRecording }
        // fn is Hold to Talk's: refused, and said so.
        harness.shortcuts.press(.function)
        await eventually { shortcuts.recorder(.tapToToggle).refusal == .alreadyUsed(by: .holdToTalk) }
        #expect(!shortcuts.recorder(.tapToToggle).isRecording)
        #expect(app.settings.tapToToggleShortcut == nil)

        shortcuts.recorderActions.record(.tapToToggle)
        await eventually { harness.shortcuts.isRecording }
        harness.shortcuts.press(.modifiers([.rightOption]))
        await eventually { app.settings.tapToToggleShortcut == .modifiers([.rightOption]) }
        await eventually { harness.shortcuts.bindings.last?[.tapToToggle] == .modifiers([.rightOption]) }
        #expect(shortcuts.recorder(.tapToToggle).keys?.modifiers == [.option(.right)])
        #expect(shortcuts.recorder(.tapToToggle).refusal == nil)

        // Cancel is safe to call again, as a recorder does when its screen disappears.
        shortcuts.recorderActions.record(.pasteAgain)
        await eventually { harness.shortcuts.isRecording }
        shortcuts.recorderActions.cancel(.pasteAgain)
        shortcuts.recorderActions.cancel(.pasteAgain)
        #expect(harness.shortcuts.cancels == 1)
        await eventually { !shortcuts.recorder(.pasteAgain).isRecording }

        shortcuts.recorderActions.clear(.tapToToggle)
        #expect(app.settings.tapToToggleShortcut == nil)
    }

    @Test func theShortcutsScreenShowsAndChangesWhatTheDoubleTapDoes() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let app = harness.app, shortcuts = harness.windows.main.shortcuts
        app.start()

        #expect(shortcuts.doubleTap == .handsFree, "hands-free by default")
        shortcuts.choose(.prompt)
        #expect(app.settings.doubleTap == .prompt)
        shortcuts.choose(.off)
        #expect(app.settings.doubleTap == .off)
        app.settings.doubleTap = .handsFree
        await eventually { shortcuts.doubleTap == .handsFree }
    }

    @Test func turningSuggestionsOffDropsTheirAudio() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults,
                              model: try makeModelDirectory(in: directory.url))
        harness.app.start()
        harness.windows.main.general.actions.setToggle(.correctionSuggestions, false)
        await eventually { harness.speech.discards == 1 }
        // With suggestions off nothing is kept for one.
        await eventually { harness.app.runtime.state.engine == .ready }
        await harness.dictate()
        await eventually { harness.speech.opened.count == 1 }
        #expect(harness.speech.opened.first?.retainForCorrection == false)
    }

    @Test func quittingLetsGoOfTheRecordingAndWaitsForThePaste() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        let app = harness.app
        app.start()
        await eventually { app.runtime.state.engine == .ready }
        app.relay.handle(.holdPressed, at: harness.clock.now)
        await eventually { if case .recording = app.runtime.state.capture { true } else { false } }

        await app.shutdown()
        #expect(app.runtime.state.capture == .idle)
        #expect(app.runtime.state.dictationCount == 0)
        #expect(harness.shortcuts.stops == 1)
        #expect(harness.inserter.idleWaits == 1)
        #expect(harness.inserter.composed.isEmpty)
    }

    @Test func quittingWaitsForTheClipboardNoLongerThanItsLimit() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        harness.app.start()
        harness.inserter.neverIdle = true
        let sleepers = harness.clock.sleeperCount
        var finished = false
        Task { @MainActor in
            await harness.app.shutdown(limit: 3)
            finished = true
        }
        await eventually { harness.clock.sleeperCount > sleepers }
        #expect(!finished)
        harness.clock.advance(by: 3)
        await eventually { finished }
        harness.inserter.becomeIdle()
    }

    @Test func aRecorderCancelledBeforeItBeganNeverTakesTheKeyboard() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        harness.app.start()
        let shortcuts = harness.windows.main.shortcuts
        shortcuts.recorderActions.record(.pasteAgain)
        shortcuts.recorderActions.cancel(.pasteAgain)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!harness.shortcuts.isRecording)
        #expect(!shortcuts.recorder(.pasteAgain).isRecording)
    }
}


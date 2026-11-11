import DictationCore
import Foundation
import Observation
import Persistence
import Synchronization
import Testing

/// Every setting over a `UserDefaults` suite of the test's own.
@MainActor
@Suite struct SettingsStoreTests {
    @Test func freshSettingsHaveTheirDefaults() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        #expect(settings.holdToTalkShortcut == .function)
        #expect(settings.tapToToggleShortcut == nil)
        #expect(settings.pasteAgainShortcut == nil)
        #expect(settings.restoreClipboard)
        #expect(settings.spokenNumbers)
        #expect(!settings.spokenDelimiters)
        #expect(!settings.pressEnterCommand)
        #expect(!settings.promptMode)
        #expect(settings.promptTag == "[dictated]")
        #expect(settings.correctionSuggestions)
        #expect(settings.keepRunLog)
        #expect(!settings.launchAtLogin)
        #expect(settings.microphoneID == nil)
        #expect(!settings.setupCompleted)
    }

    @Test func everySettingSurvivesARelaunch() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        let toggle = ShortcutBinding.key(code: 49, modifiers: [.option])
        let paste = ShortcutBinding.modifiers([.rightCommand, .rightOption])
        settings.holdToTalkShortcut = .modifiers([.rightOption])
        settings.tapToToggleShortcut = toggle
        settings.pasteAgainShortcut = paste
        settings.restoreClipboard = false
        settings.spokenNumbers = false
        settings.spokenDelimiters = true
        settings.pressEnterCommand = true
        settings.promptMode = true
        settings.promptTag = "[voice]"
        settings.correctionSuggestions = false
        settings.keepRunLog = false
        settings.launchAtLogin = true
        settings.microphoneID = "synthetic-microphone"
        settings.setupCompleted = true

        let reopened = SettingsStore(defaults: suite.defaults)
        #expect(reopened.holdToTalkShortcut == .modifiers([.rightOption]))
        #expect(reopened.tapToToggleShortcut == toggle)
        #expect(reopened.pasteAgainShortcut == paste)
        #expect(!reopened.restoreClipboard)
        #expect(!reopened.spokenNumbers)
        #expect(reopened.spokenDelimiters)
        #expect(reopened.pressEnterCommand)
        #expect(reopened.promptMode)
        #expect(reopened.promptTag == "[voice]")
        #expect(!reopened.correctionSuggestions)
        #expect(!reopened.keepRunLog)
        #expect(reopened.launchAtLogin)
        #expect(reopened.microphoneID == "synthetic-microphone")
        #expect(reopened.setupCompleted)
    }

    @Test func aRemovedShortcutStaysRemoved() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.holdToTalkShortcut = nil
        #expect(SettingsStore(defaults: suite.defaults).holdToTalkShortcut == nil, "nil is not the Fn default")
    }

    @Test func choosingTheSystemMicrophoneAgainForgetsTheChoice() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.microphoneID = "synthetic-microphone"
        settings.microphoneID = nil
        #expect(SettingsStore(defaults: suite.defaults).microphoneID == nil)
    }

    @Test func anUndecodableValueFallsBackWithoutLosingTheOthers() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.tapToToggleShortcut = .key(code: 49, modifiers: [.control])
        settings.spokenDelimiters = true
        settings.promptTag = "[voice]"
        // Values an older or hand-edited store might hold.
        suite.defaults.set(Data("not json".utf8), forKey: "holdToTalkShortcut")
        suite.defaults.set("yes", forKey: "spokenNumbers")
        suite.defaults.set(7, forKey: "restoreClipboard")
        suite.defaults.set(42, forKey: "microphoneID")
        suite.defaults.set(Data(#"{"key":{"code":"x"}}"#.utf8), forKey: "pasteAgainShortcut")

        let reopened = SettingsStore(defaults: suite.defaults)
        #expect(reopened.holdToTalkShortcut == .function)
        #expect(reopened.spokenNumbers)
        #expect(reopened.restoreClipboard)
        #expect(reopened.microphoneID == nil)
        #expect(reopened.pasteAgainShortcut == nil)
        #expect(reopened.tapToToggleShortcut == .key(code: 49, modifiers: [.control]))
        #expect(reopened.spokenDelimiters)
        #expect(reopened.promptTag == "[voice]")
    }

    /// Saved settings are found by these names, so renaming one would silently reset it for every user.
    @Test func storedNamesNeverChange() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        settings.holdToTalkShortcut = nil
        settings.tapToToggleShortcut = .function
        settings.pasteAgainShortcut = .function
        settings.restoreClipboard = false
        settings.spokenNumbers = false
        settings.spokenDelimiters = true
        settings.pressEnterCommand = true
        settings.promptMode = true
        settings.promptTag = "[voice]"
        settings.correctionSuggestions = false
        settings.keepRunLog = false
        settings.launchAtLogin = true
        settings.microphoneID = "synthetic-microphone"
        settings.setupCompleted = true
        let stored = Set(suite.defaults.persistentDomain(forName: suite.suiteName)?.keys.map { $0 } ?? [])
        #expect(stored == [
            "holdToTalkShortcut", "tapToToggleShortcut", "pasteAgainShortcut", "restoreClipboard", "spokenNumbers",
            "spokenDelimiters", "pressEnterCommand", "promptMode", "promptTag", "correctionSuggestions", "keepRunLog",
            "launchAtLogin", "microphoneID", "setupCompleted",
        ])
    }

    @Test func shortcutsCanBeReachedByAction() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        let binding = ShortcutBinding.key(code: 9, modifiers: [.command, .shift])
        settings.setShortcut(binding, for: .pasteAgain)
        #expect(settings.pasteAgainShortcut == binding)
        #expect(settings.shortcut(for: .pasteAgain) == binding)
        #expect(settings.shortcut(for: .holdToTalk) == .function)
        settings.setShortcut(nil, for: .holdToTalk)
        #expect(settings.holdToTalkShortcut == nil)
        #expect(settings.shortcut(for: .tapToToggle) == nil)
    }

    @Test func aChangeIsObserved() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        let changed = Flag()
        withObservationTracking {
            _ = settings.keepRunLog
        } onChange: {
            changed.set()
        }
        settings.promptTag = "[voice]"
        #expect(!changed.isSet, "an unrelated setting does not notify")
        settings.keepRunLog = false
        #expect(changed.isSet)
    }
}

/// A flag an observation callback can set from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

import Foundation
import Persistence
import Testing
import TextRules

/// What the `sorello` command reads of an app's data (ARCHITECTURE.md, section 10, "The command"): the text rules the
/// settings give, and the macros, read without changing a byte. Every command and text is invented.
@MainActor
@Suite struct ReadOnlyTests {
    /// The rules come from the settings that make them, and nothing else.
    @Test func theRulesAreTheOnesTheSettingsSay() throws {
        let suite = try TemporaryDefaults()
        let settings = SettingsStore(defaults: suite.defaults)
        let macro = VoiceMacro(command: "blue bird", text: "Synthetic replacement.")
        #expect(TextRuleOptions(settings: settings, macros: [macro])
                == TextRuleOptions(macros: [macro], pressEnterCommand: false, spokenNumbers: true,
                                   spokenDelimiters: false, promptTag: "[dictated]"), "The defaults")
        settings.pressEnterCommand = true
        settings.spokenNumbers = false
        settings.spokenDelimiters = true
        settings.promptTag = "[spoken]"
        settings.restoreClipboard = false
        settings.correctionSuggestions = false
        #expect(TextRuleOptions(settings: SettingsStore(defaults: suite.defaults), macros: [])
                == TextRuleOptions(macros: [], pressEnterCommand: true, spokenNumbers: false, spokenDelimiters: true,
                                   promptTag: "[spoken]"), "As saved, read by a store of its own")
    }

    @Test func macrosAreReadAsSaved() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Support/macros.json")
        #expect(MacroStore.readWithoutChanging(url) == [])
        #expect(directory.contents().isEmpty, "No directory is made for a file that is not there")

        let store = MacroStore(fileURL: url)
        let first = try store.add(command: "blue bird", text: "Synthetic replacement.")
        let second = try store.add(command: "sign off", text: "")
        #expect(MacroStore.readWithoutChanging(url) == [first, second])
    }

    /// A file that cannot be read is nil, and stays exactly where and what it was, where opening a store would move
    /// it aside.
    @Test(arguments: [Data("not json".utf8), Data(#"{"version":2,"macros":[]}"#.utf8), Data()])
    func anUnreadableFileIsLeftAlone(contents: Data) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        try contents.write(to: url)
        #expect(MacroStore.readWithoutChanging(url) == nil)
        #expect(try Data(contentsOf: url) == contents)
        #expect(directory.contents() == ["macros.json"])
    }

    @Test func aFileThatCannotBeOpenedIsLeftAlone() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        try store.add(command: "blue bird", text: "Synthetic replacement.")
        let saved = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(MacroStore.readWithoutChanging(url) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == saved)
        #expect(directory.contents() == ["macros.json"])
    }
}

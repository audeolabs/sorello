import Foundation
import Persistence
import Testing
import TextRules

/// The voice macros in `macros.json`. All commands and texts are invented.
@MainActor
@Suite struct MacroStoreTests {
    private struct StoredFile: Decodable {
        var version: Int
        var macros: [VoiceMacro]
    }

    private func stored(_ url: URL) throws -> StoredFile {
        try JSONDecoder().decode(StoredFile.self, from: Data(contentsOf: url))
    }

    @Test func aMissingFileIsAnEmptyList() throws {
        let directory = try TemporaryDirectory()
        let store = MacroStore(fileURL: directory.url.appendingPathComponent("macros.json"))
        #expect(store.macros.isEmpty)
        #expect(directory.contents().isEmpty, "reading writes nothing")
    }

    @Test func macrosSurviveARelaunchInOrder() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        let first = try store.add(command: "  Blue bird ", text: "Synthetic replacement.\n")
        let second = try store.add(command: "sign off", text: "")
        #expect(first.command == "Blue bird", "the command is trimmed")
        #expect(first.text == "Synthetic replacement.\n", "the text is kept exactly")
        #expect(store.macros == [first, second])

        #expect(MacroStore(fileURL: url).macros == [first, second])
        let file = try stored(url)
        #expect(file.version == 1)
        #expect(file.macros == [first, second])
    }

    @Test(arguments: ["", "   ", "?!", " ... "])
    func anUnsayableCommandIsRefused(command: String) throws {
        let directory = try TemporaryDirectory()
        let store = MacroStore(fileURL: directory.url.appendingPathComponent("macros.json"))
        #expect(throws: MacroStoreError.emptyCommand) { try store.add(command: command, text: "Synthetic") }
        #expect(store.macros.isEmpty)
    }

    @Test func aCommandTheMatcherWouldConfuseIsRefused() throws {
        let directory = try TemporaryDirectory()
        let store = MacroStore(fileURL: directory.url.appendingPathComponent("macros.json"))
        try store.add(command: "Blue bird", text: "first")
        #expect(throws: MacroStoreError.duplicateCommand) { try store.add(command: "blue, BIRD!", text: "second") }
        #expect(store.macros.map(\.text) == ["first"])
    }

    @Test func editingKeepsThePlaceAndChecksTheCommand() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        let first = try store.add(command: "alpha", text: "one")
        var second = try store.add(command: "beta", text: "two")

        second.text = "two, edited"
        second.command = "Beta."
        try store.update(second)
        #expect(store.macros.map(\.text) == ["one", "two, edited"], "a macro may keep its own command")

        second.command = "ALPHA"
        #expect(throws: MacroStoreError.duplicateCommand) { try store.update(second) }
        second.command = " "
        #expect(throws: MacroStoreError.emptyCommand) { try store.update(second) }
        #expect(throws: MacroStoreError.notFound) {
            try store.update(VoiceMacro(command: "gamma", text: "three"))
        }
        #expect(store.macros.map(\.command) == ["alpha", "Beta."])
        #expect(MacroStore(fileURL: url).macros.map(\.id) == [first.id, second.id])
    }

    @Test func deleteRemovesOne() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        let first = try store.add(command: "alpha", text: "one")
        let second = try store.add(command: "beta", text: "two")
        try store.delete(id: first.id)
        try store.delete(id: UUID())
        #expect(store.macros == [second])
        #expect(MacroStore(fileURL: url).macros == [second])
    }

    @Test func reorderingFollowsDragAndDrop() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        for name in ["a", "b", "c", "d"] { try store.add(command: name, text: name) }
        try store.move(fromOffsets: [0], toOffset: 4)
        #expect(store.macros.map(\.command) == ["b", "c", "d", "a"])
        try store.move(fromOffsets: [2, 3], toOffset: 0)
        #expect(store.macros.map(\.command) == ["d", "a", "b", "c"])
        try store.move(fromOffsets: [1], toOffset: 1)
        try store.move(fromOffsets: [9], toOffset: 0)
        #expect(store.macros.map(\.command) == ["d", "a", "b", "c"])
        #expect(MacroStore(fileURL: url).macros.map(\.command) == ["d", "a", "b", "c"])
    }

    @Test(arguments: [
        Data("not json".utf8),
        Data(#"{"version":1,"macros":[{"id":"#.utf8),
        Data(#"{"version":2,"macros":[],"future":true}"#.utf8),
        Data(#"{"macros":[]}"#.utf8),
    ])
    func anUnreadableFileIsMovedAsideAndReplaced(contents: Data) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        try contents.write(to: url)

        let store = MacroStore(fileURL: url)
        #expect(store.macros.isEmpty)
        let names = directory.contents()
        #expect(names.count == 2)
        let aside = try #require(names.first { $0.hasPrefix("macros.json.unreadable-") })
        #expect(try Data(contentsOf: directory.url.appendingPathComponent(aside)) == contents, "nothing is lost")
        let replacement = try stored(url)
        #expect(replacement.version == 1)
        #expect(replacement.macros.isEmpty)
    }

    @Test func anUnreadableFileThatCannotBeMovedIsNeverOverwritten() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let original = Data(#"{"version":9,"macros":"from a newer app"}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }

        let store = MacroStore(fileURL: url)
        #expect(store.macros.isEmpty)
        #expect(throws: MacroStoreError.saveFailed) { try store.add(command: "alpha", text: "one") }
        #expect(try Data(contentsOf: url) == original)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path)
        let added = try store.add(command: "alpha", text: "one")
        let aside = try #require(directory.contents().first { $0.hasPrefix("macros.json.unreadable-") })
        #expect(try Data(contentsOf: directory.url.appendingPathComponent(aside)) == original, "nothing is lost")
        #expect(MacroStore(fileURL: url).macros == [added])
    }

    @Test func theProtectionOutlivesAFolderThatCannotBeSearched() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let original = Data("not json".utf8)
        try original.write(to: url)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }
        let store = MacroStore(fileURL: url)

        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.url.path)
        #expect(throws: MacroStoreError.saveFailed) { try store.add(command: "alpha", text: "one") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path)
        try store.add(command: "beta", text: "two")
        let aside = try #require(directory.contents().first { $0.hasPrefix("macros.json.unreadable-") })
        #expect(try Data(contentsOf: directory.url.appendingPathComponent(aside)) == original)
    }

    @Test func aFileThatCannotBeOpenedIsKeptNotReplaced() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let first = MacroStore(fileURL: url)
        let saved = try first.add(command: "alpha", text: "one")
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = MacroStore(fileURL: url)
        #expect(store.macros.isEmpty)
        try store.add(command: "beta", text: "two")
        let aside = try #require(directory.contents().first { $0.hasPrefix("macros.json.unreadable-") })
        let asideURL = directory.url.appendingPathComponent(aside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path)
        #expect(try Data(contentsOf: asideURL) == original, "the unopenable file is moved, not overwritten")
        #expect(try JSONDecoder().decode(StoredFile.self, from: original).macros == [saved])
    }

    @Test func aChangeThatCannotBeSavedChangesNothing() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        let kept = try store.add(command: "alpha", text: "one")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }

        #expect(throws: MacroStoreError.saveFailed) { try store.add(command: "beta", text: "two") }
        #expect(throws: MacroStoreError.saveFailed) { try store.delete(id: kept.id) }
        #expect(store.macros == [kept])
        #expect(MacroStore(fileURL: url).macros == [kept])
    }

    @Test func writesOnlyItsOwnFileOwnerOnly() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("macros.json")
        let store = MacroStore(fileURL: url)
        try store.add(command: "alpha", text: "one")
        try store.add(command: "beta", text: "two")
        try store.move(fromOffsets: [1], toOffset: 0)
        #expect(directory.contents() == ["data", "data/macros.json"])
        #expect(try permissions(of: url) == 0o600)
        #expect(try permissions(of: url.deletingLastPathComponent()) == 0o700)
    }
}

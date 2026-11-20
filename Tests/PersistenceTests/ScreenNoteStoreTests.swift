import Foundation
import Persistence
import Testing

/// ARCHITECTURE.md, section 14, "Where notes are kept".
@Suite struct ScreenNoteStoreTests {
    static func store() -> ScreenNoteStore {
        ScreenNoteStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-notes-\(UUID().uuidString)", isDirectory: true))
    }

    static let utc = TimeZone(identifier: "UTC")!

    static func finish(_ folder: URL) throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent(ScreenNoteStore.manifestName))
    }

    @Test func aFolderIsNamedByTheStartAndPrivate() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeFolder(startedAt: date, timeZone: Self.utc)
        #expect(folder.lastPathComponent == "2027-01-15-080000")
        let again = try store.makeFolder(startedAt: date, timeZone: Self.utc)
        #expect(again.lastPathComponent == "2027-01-15-080000-2")
        for path in [store.directory.path, folder.path] {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    @Test func onlyFinishedNotesCountNewestFirst() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let older = try store.makeFolder(startedAt: Date(timeIntervalSince1970: 1_000), timeZone: Self.utc)
        let newer = try store.makeFolder(startedAt: Date(timeIntervalSince1970: 2_000), timeZone: Self.utc)
        let unfinished = try store.makeFolder(startedAt: Date(timeIntervalSince1970: 3_000), timeZone: Self.utc)
        try Self.finish(older)
        try Self.finish(newer)
        #expect(store.notes().map(\.lastPathComponent) == [newer, older].map(\.lastPathComponent))
        #expect(store.latest()?.lastPathComponent == newer.lastPathComponent)
        store.removeUnfinished()
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
        #expect(FileManager.default.fileExists(atPath: older.path))
    }

    @Test func theNewestIsTheLastMadeEvenWhenTheClockWentBack() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = try store.makeFolder(startedAt: Date(timeIntervalSince1970: 5_000), timeZone: Self.utc)
        // An hour back, as when daylight saving ends: the later note's name sorts before the earlier one's.
        let second = try store.makeFolder(startedAt: Date(timeIntervalSince1970: 5_000 - 3600), timeZone: Self.utc)
        try Self.finish(first)
        try Self.finish(second)
        #expect(store.latest()?.lastPathComponent == second.lastPathComponent)
    }

    @Test func pruningKeepsTheNewestTwenty() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var made: [URL] = []
        for index in 0..<23 {
            let folder = try store.makeFolder(startedAt: Date(timeIntervalSince1970: Double(index) * 60), timeZone: Self.utc)
            try Self.finish(folder)
            made.append(folder)
        }
        store.prune()
        #expect(store.notes().count == ScreenNoteStore.kept)
        for folder in made.prefix(3) { #expect(!FileManager.default.fileExists(atPath: folder.path)) }
        for folder in made.suffix(20) { #expect(FileManager.default.fileExists(atPath: folder.path)) }
    }

    @Test func deleteTouchesOnlyItsOwnFolders() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        store.delete(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let folder = try store.makeFolder(startedAt: Date(), timeZone: Self.utc)
        store.delete(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

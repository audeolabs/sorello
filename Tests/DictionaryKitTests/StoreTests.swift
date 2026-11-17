import Foundation
import Testing
@testable import DictionaryKit

/// `dictionary.json` and the store that owns it (ARCHITECTURE.md, section 7; DESIGN §3.2, §3.3).
struct StoreTests {
    /// A private temporary directory, removed when the test ends.
    final class Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictionaryStoreTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { directory.appendingPathComponent("Support/dictionary.json") }

        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: directory)
        }

        func entries() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []).sorted()
        }
    }

    @Test func fileRoundTripsAndRejectsCorruption() throws {
        let valid = fileData(entries: [["text": "NixOS", "strength": 1.41], ["text": "New York", "strength": 1]],
                             ignore: ["eldar"])
        let loaded = try #require(DictionaryFile.decode(valid, encoder: testEncoder), "Valid file must load")
        #expect(loaded.dictionary.entries.map(\.strength) == [1.41, 1])
        #expect(loaded.dictionary.ignore == [DictionaryKey("eldar")], "Ignore keys load")
        let reloaded = try #require(DictionaryFile.decode(DictionaryFile.encode(loaded), encoder: testEncoder))
        #expect(reloaded == loaded, "The file round-trips")

        let app: [String: Any] = ["id": "com.example.chat", "name": "Chat"]
        let corrupt: [Data] = [
            Data("not json".utf8),
            Data(#"["eldar"]"#.utf8),
            fileData(version: 2),
            Data(#"{"entries":[],"ignore":[],"apps":[]}"#.utf8),
            Data(#"{"version":1,"ignore":[],"apps":[]}"#.utf8),
            Data(#"{"version":1,"entries":[],"apps":[]}"#.utf8),
            Data(#"{"version":1,"entries":[],"ignore":[]}"#.utf8),
            fileData(entries: [["text": "NixOS", "strength": 9]]),
            fileData(entries: [["text": "  NixOS", "strength": 1]]),
            fileData(entries: [["text": "NixOS", "strength": 1], ["text": "nixos", "strength": 2]]),
            fileData(entries: [["text": "naïve—x", "strength": 1]]),
            fileData(entries: [["text": "NixOS"]]),
            fileData(ignore: ["Eldar"]),
            fileData(ignore: ["eldar", "eldar"]),
            fileData(ignore: [""]),
            fileData(apps: [["id": "com example", "name": "Chat"]]),
            fileData(apps: [["id": "com.example.chat", "name": " Chat"]]),
            fileData(apps: [["id": "com.example.chat", "name": ""]]),
            fileData(apps: [["id": "com.example.chat"]]),
            fileData(apps: [app, app]),
            fileData(entries: [["text": "Zorbik", "strength": 1, "apps": []]], apps: [app]),
            fileData(entries: [["text": "Zorbik", "strength": 1, "apps": ["com.example.mail"]]], apps: [app]),
            fileData(entries: [["text": "Zorbik", "strength": 1, "apps": ["com.example.chat", "com.example.chat"]]],
                     apps: [app]),
            // Spellings (§3.7): absent when there are none, normalized, each once, at most four, never the word, no
            // comma, and never another entry's word or spelling.
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": []]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": "Sarello"]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["so  rello"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["Sarello", "sarello"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["a", "b", "c", "d", "e"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["sorello"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["so, rello"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["1234"]]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["Sarello"]],
                               ["text": "sarello", "strength": 1]]),
            fileData(entries: [["text": "Sorello", "strength": 1, "soundsLike": ["Sarello"]],
                               ["text": "Plexa", "strength": 1, "soundsLike": ["SARELLO"]]]),
        ]
        for data in corrupt {
            #expect(DictionaryFile.decode(data, encoder: testEncoder) == nil,
                    "Corrupt file must be rejected: \(String(decoding: data, as: UTF8.self))")
        }
        let tooMany = fileData(entries: (0...DictionaryValidation.capacity).map { ["text": "w\($0)x", "strength": 1] })
        #expect(DictionaryFile.decode(tooMany, encoder: testEncoder) == nil, "More than 1000 entries is corrupt")
        let tooManyApps = fileData(apps: (0...DictionaryAppScopes.appCapacity).map {
            ["id": "com.example.app\($0)", "name": "App"]
        })
        #expect(DictionaryFile.decode(tooManyApps, encoder: testEncoder) == nil, "More than 32 apps is corrupt")
        #expect(DictionaryFile.decode(Data(count: DictionaryFile.maxBytes + 1), encoder: testEncoder) == nil,
                "Over the size cap is corrupt")
    }

    /// What Sorello 0.0.1 wrote: its `fileFormat` test's file, which `DictionaryFile` produced unchanged from that
    /// tag until spellings. It loads unchanged, without spellings, and is written back byte for byte.
    @Test func aFileFromSorello001LoadsUnchanged() throws {
        let written = #"{"apps":[{"id":"com.example.chat","name":"Chat"},{"id":"com.example.mail","name":"Mail"}],"entries":[{"strength":1,"text":"Kubernetes"},{"apps":["com.example.chat","com.example.mail"],"strength":1.5,"text":"Plexa"}],"ignore":["a/b"],"version":1}"#
        let loaded = try #require(DictionaryFile.decode(Data(written.utf8), encoder: testEncoder))
        #expect(loaded.dictionary.entries == [entry("Kubernetes"), entry("Plexa", 1.5)])
        #expect(loaded.dictionary.entries.allSatisfy { $0.soundsLike.isEmpty })
        #expect(loaded.scopes.apps(for: DictionaryKey("plexa")) == ["com.example.chat", "com.example.mail"])
        #expect(loaded.dictionary.ignore == [DictionaryKey("a/b")])
        #expect(String(decoding: DictionaryFile.encode(loaded), as: UTF8.self) == written)

        // Through the store: it opens, and a change that adds no spelling writes no spelling key.
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(written.utf8).write(to: scratch.file)
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(store.opening == .loaded)
        #expect(store.dictionary == loaded)
        try store.save(text: "Kubernetes", strength: 2, replacing: DictionaryKey("kubernetes"))
        let saved = String(decoding: try Data(contentsOf: scratch.file), as: UTF8.self)
        #expect(saved == written.replacingOccurrences(of: #"{"strength":1,"text":"Kubernetes"}"#,
                                                       with: #"{"strength":2,"text":"Kubernetes"}"#))
    }

    @Test func fileFormat() throws {
        var scoped = ScopedDictionary()
        let chat = try #require(DictionaryApp(id: "com.example.chat", name: "Chat"))
        let mail = try #require(DictionaryApp(id: "com.example.mail", name: "Mail"))
        #expect({ scoped.scopes.register(chat) }() == nil)
        #expect({ scoped.scopes.register(mail) }() == nil)
        #expect({ scoped.dictionary.upsert(entry("Kubernetes")) }() == nil)
        #expect({ scoped.dictionary.upsert(entry("Plexa", 1.5)) }() == nil)
        #expect({ scoped.scopes.setApps(["com.example.mail", "com.example.chat"], for: DictionaryKey("plexa")) }() == nil)
        #expect({ scoped.dictionary.addIgnore(DictionaryKey("a/b")) }() == nil)
        #expect(String(decoding: DictionaryFile.encode(scoped), as: UTF8.self)
                == #"{"apps":[{"id":"com.example.chat","name":"Chat"},{"id":"com.example.mail","name":"Mail"}],"entries":[{"strength":1,"text":"Kubernetes"},{"apps":["com.example.chat","com.example.mail"],"strength":1.5,"text":"Plexa"}],"ignore":["a/b"],"version":1}"#)
    }

    /// Spellings sit in the entry, in the user's order, between its apps and its strength (sorted keys).
    @Test func fileFormatWithSpellings() throws {
        var scoped = ScopedDictionary()
        let chat = try #require(DictionaryApp(id: "com.example.chat", name: "Chat"))
        #expect({ scoped.scopes.register(chat) }() == nil)
        #expect({ scoped.dictionary.upsert(DictionaryEntry(text: "Sorello", strength: 1,
                                                          soundsLike: ["so rello", "Sarello"])) }() == nil)
        #expect({ scoped.scopes.setApps(["com.example.chat"], for: DictionaryKey("sorello")) }() == nil)
        #expect({ scoped.dictionary.upsert(entry("Plexa", 1.5)) }() == nil)
        let stored = DictionaryFile.encode(scoped)
        #expect(String(decoding: stored, as: UTF8.self)
                == #"{"apps":[{"id":"com.example.chat","name":"Chat"}],"entries":[{"apps":["com.example.chat"],"soundsLike":["so rello","Sarello"],"strength":1,"text":"Sorello"},{"strength":1.5,"text":"Plexa"}],"ignore":[],"version":1}"#)
        #expect(DictionaryFile.decode(stored, encoder: testEncoder) == scoped, "It round-trips")
    }

    /// Whatever `encode` writes must load again: every entry limited to every app with the longest identifiers and
    /// with the most and longest spellings, and the longest keys and names, of four-byte scalars.
    @Test func fullFileLoadsAgain() throws {
        let wide = String(repeating: "\u{20000}", count: DictionaryApp.maxNameScalars)
        let apps = try (0..<DictionaryAppScopes.appCapacity).map { index in
            try #require(DictionaryApp(id: String(format: "%03d", index) + String(repeating: "a", count: DictionaryApp.maxIDLength - 3),
                                       name: wide))
        }
        var scoped = ScopedDictionary()
        for app in apps { #expect({ scoped.scopes.register(app) }() == nil) }
        let ids = Set(apps.map(\.id))
        for index in 0..<DictionaryValidation.capacity {
            // U+20000 and its neighbours are letters (Lo) with no case mapping, four bytes each in UTF-8.
            let text = DictionaryText.string([Unicode.Scalar(0x20000 + index) ?? "a"]
                + Array(repeating: Unicode.Scalar(0x20000) ?? "a", count: DictionaryValidation.maxScalars - 1))
            var item = try DictionaryValidation.validate(text: text, strength: 1, encoder: nil).get()
            item.soundsLike = (0..<SoundsLike.maxSpellings).map { spelling in
                DictionaryText.string([Unicode.Scalar(0x21000 + index * SoundsLike.maxSpellings + spelling) ?? "a"]
                    + Array(repeating: Unicode.Scalar(0x20000) ?? "a", count: DictionaryValidation.maxScalars - 1))
            }
            #expect({ scoped.dictionary.upsert(item) }() == nil)
            #expect({ scoped.scopes.setApps(ids, for: item.key) }() == nil)
        }
        for index in 0..<DictionaryValidation.ignoreCapacity {
            let key = DictionaryKey(folded: [Unicode.Scalar(0x20000 + index) ?? "a"]
                + Array(repeating: Unicode.Scalar(0x20000) ?? "a", count: DictionaryKey.maxScalars - 1))
            #expect({ scoped.dictionary.addIgnore(key) }() == nil)
        }
        let stored = DictionaryFile.encode(scoped)
        #expect(stored.count > 7 << 20, "The largest file is several MiB: \(stored.count) bytes")
        #expect(stored.count <= DictionaryFile.maxBytes, "and stays within the load cap")
        #expect(DictionaryFile.decode(stored, encoder: nil) == scoped, "The largest file round-trips")
    }

    @Test func storeStartsEmptyAndSavesPrivately() throws {
        let scratch = Scratch()
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(store.opening == .new)
        #expect(store.dictionary == ScopedDictionary() && store.canEdit)
        #expect(!FileManager.default.fileExists(atPath: scratch.file.path), "Nothing is written before a change")
        let first = store.revision

        try store.save(text: "  Zorblax ", strength: 1.41)
        #expect(store.revision == first + 1, "A change raises the revision")
        expectScalars(store.dictionary.dictionary.entries.first?.text ?? "", "Zorblax")
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Only the user can read the file")
        let folder = try FileManager.default.attributesOfItem(atPath: scratch.file.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "or its directory")
        #expect(scratch.entries() == ["dictionary.json"], "No temporary file is left behind")

        // An edit that changes nothing is neither written nor published.
        try store.ignore(DictionaryKey("eldar"))
        let revision = store.revision
        try store.ignore(DictionaryKey("ELDAR"))
        #expect(store.revision == revision)
        #expect(try store.remove(DictionaryKey("absent")) == false)
        #expect(try store.unignore(DictionaryKey("absent")) == false)
        #expect(store.revision == revision)

        // The next launch loads what was saved.
        let again = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(again.opening == .loaded)
        #expect(again.dictionary == store.dictionary)
    }

    @Test func refusedChangesChangeNothing() throws {
        let scratch = Scratch()
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try store.save(text: "Zorblax", strength: 1)
        let before = (store.dictionary, store.revision)
        #expect(throws: DictionaryChangeError.invalid(.unencodable)) { try store.save(text: "naïve—x", strength: 1) }
        #expect(throws: DictionaryChangeError.invalid(.invalidStrength)) { try store.save(text: "Quint", strength: 9) }
        #expect(throws: DictionaryChangeError.unknownApp) {
            try store.save(text: "Quint", strength: 1, apps: ["com.example.unknown"])
        }
        #expect(store.dictionary == before.0 && store.revision == before.1)

        // A file that cannot be written refuses the change, and memory keeps the old dictionary.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.file.deletingLastPathComponent().path)
        #expect(throws: DictionaryChangeError.notSaved) { try store.save(text: "Quint", strength: 1) }
        #expect(store.dictionary == before.0 && store.revision == before.1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.file.deletingLastPathComponent().path)
        try store.save(text: "Quint", strength: 1)
        #expect(store.dictionary.dictionary.contains(DictionaryKey("quint")))
    }

    /// The app never fails to launch over data: an unreadable file is moved aside and replaced with an empty one.
    @Test func unreadableFileIsMovedAside() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("synthetic garbage".utf8)
        try garbage.write(to: scratch.file)
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        guard case .replacedUnreadable(let moved?) = store.opening else {
            Issue.record("Expected the file to be moved aside, got \(store.opening)")
            return
        }
        #expect(try Data(contentsOf: moved) == garbage, "The unreadable file is kept as it was")
        #expect(moved.lastPathComponent.hasPrefix("dictionary-unreadable-") && moved.pathExtension == "json")
        #expect(store.dictionary == ScopedDictionary() && store.canEdit)
        #expect(DictionaryFile.decode(try Data(contentsOf: scratch.file), encoder: testEncoder) == ScopedDictionary(),
                "An empty dictionary replaces it")
        try store.save(text: "Zorblax", strength: 1)

        // A second unreadable file never overwrites the first one moved aside.
        try garbage.write(to: scratch.file)
        let next = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        guard case .replacedUnreadable(let second?) = next.opening else {
            Issue.record("Expected the file to be moved aside, got \(next.opening)")
            return
        }
        #expect(second != moved && FileManager.default.fileExists(atPath: moved.path))

        // An entry the vocabulary cannot spell makes the file unreadable too.
        try fileData(entries: [["text": "naïve—x", "strength": 1]]).write(to: scratch.file)
        #expect(DictionaryStore(fileURL: scratch.file, encoder: nil).opening == .loaded, "Without a vocabulary it loads")
        guard case .replacedUnreadable = DictionaryStore(fileURL: scratch.file, encoder: testEncoder).opening else {
            Issue.record("An unencodable entry must make the file unreadable")
            return
        }
    }

    @Test func unmovableFileIsLeftAlone() throws {
        let scratch = Scratch()
        let folder = scratch.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("synthetic garbage".utf8).write(to: scratch.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(store.opening == .replacedUnreadable(movedTo: nil))
        #expect(!store.canEdit, "Nothing may be saved over a file that could not be moved")
        #expect(throws: DictionaryChangeError.notSaved) { try store.save(text: "Zorblax", strength: 1) }
        #expect(try Data(contentsOf: scratch.file) == Data("synthetic garbage".utf8))
    }

    /// A file that is there but cannot be opened (a permission problem, not damage) is left alone: not moved, deleted
    /// or written over. The store works without it, and opens it once it can.
    @Test func unopenableFileIsLeftAlone() throws {
        let scratch = Scratch()
        let writer = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try writer.save(text: "Zorblax", strength: 2)
        let saved = try Data(contentsOf: scratch.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratch.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.file.path) }

        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(store.opening == .unopenable)
        #expect(store.dictionary == ScopedDictionary() && store.canEdit)
        #expect(throws: DictionaryChangeError.notSaved) { try store.save(text: "Quint", strength: 1) }
        #expect(scratch.entries() == ["dictionary.json"], "Nothing is moved aside")

        // Once it opens, the next change starts from what it holds.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.file.path)
        #expect(try Data(contentsOf: scratch.file) == saved, "Nothing was written over it")
        let revision = store.revision
        try store.save(text: "Quint", strength: 1)
        #expect(store.dictionary.dictionary.entries.map(\.text) == ["Zorblax", "Quint"])
        #expect(store.revision > revision + 1, "Adopting the file is a change of its own")
    }

    /// A directory that may not be searched hides whether the file is there; it is treated as a file that cannot
    /// be opened, never as a missing one, so a dictionary inside is not written over once the directory opens.
    @Test func unsearchableDirectoryIsNotAnEmptyDictionary() throws {
        let scratch = Scratch()
        let writer = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try writer.save(text: "Zorblax", strength: 2)
        let folder = scratch.file.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }

        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(store.opening == .unopenable)
        #expect(throws: DictionaryChangeError.notSaved) { try store.save(text: "Quint", strength: 1) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        try store.save(text: "Quint", strength: 1)
        #expect(store.dictionary.dictionary.entries.map(\.text) == ["Zorblax", "Quint"], "The hidden dictionary survives")
    }

    /// Without the model's vocabulary nothing may change, and saved data loads as it is.
    @Test func editsNeedVocabulary() throws {
        let scratch = Scratch()
        let writer = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try writer.save(text: "Kubernetes", strength: 1.41)
        try writer.ignore(DictionaryKey("eldar"))
        let stored = try Data(contentsOf: scratch.file)

        let locked = DictionaryStore(fileURL: scratch.file, encoder: nil)
        #expect(locked.opening == .loaded && locked.dictionary == writer.dictionary, "Loaded unchanged")
        #expect(!locked.canEdit, "No vocabulary, no edits")
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.save(text: "NixOS", strength: 1) }
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.remove(DictionaryKey("kubernetes")) }
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.ignore(DictionaryKey("nixos")) }
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.unignore(DictionaryKey("eldar")) }
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.add("Vantor", strength: 1, to: nil) }
        #expect(throws: DictionaryChangeError.noVocabulary) { try locked.removeApp(id: "com.example.chat") }
        #expect(try Data(contentsOf: scratch.file) == stored, "The file is untouched")
        #expect(DictionaryStore(fileURL: scratch.file, encoder: testEncoder).dictionary == writer.dictionary,
                "The same data loads once the vocabulary is back")
    }

    /// A downloaded model brings its vocabulary to a store that opened without one: from then on it can be changed,
    /// without being opened again. A store keeps the first vocabulary it has.
    @Test func aVocabularyThatArrivesLaterAllowsEdits() throws {
        let scratch = Scratch()
        let writer = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try writer.save(text: "Kubernetes", strength: 1.41)
        let store = DictionaryStore(fileURL: scratch.file, encoder: nil)
        #expect(!store.canEdit)
        let revision = store.revision
        #expect(store.adoptVocabulary(testEncoder))
        #expect(store.canEdit)
        #expect(store.revision == revision && store.dictionary == writer.dictionary, "Nothing it held changed")
        try store.save(text: "NixOS", strength: 1)
        #expect(store.dictionary.dictionary.entries.map(\.text) == ["Kubernetes", "NixOS"])
        #expect(!store.adoptVocabulary(testEncoder), "A store keeps the vocabulary it has")
        #expect(DictionaryStore(fileURL: scratch.file, encoder: testEncoder).dictionary == store.dictionary)
    }

    @Test func capacities() throws {
        let scratch = Scratch()
        var scoped = ScopedDictionary()
        for index in 0..<DictionaryValidation.capacity { _ = scoped.dictionary.upsert(entry("word\(index)x")) }
        for index in 0..<DictionaryValidation.ignoreCapacity { _ = scoped.dictionary.addIgnore(DictionaryKey("w\(index)")) }
        try FileManager.default.createDirectory(at: scratch.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DictionaryFile.encode(scoped).write(to: scratch.file)
        let full = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(full.opening == .loaded)
        #expect(throws: DictionaryChangeError.full) { try full.save(text: "NixOS", strength: 1) }
        #expect(throws: DictionaryChangeError.ignoreFull) { try full.ignore(DictionaryKey("eldar")) }
        try full.save(text: "WORD0X", strength: 3, replacing: DictionaryKey("word0x"))
        #expect(full.dictionary.dictionary.entries.first == entry("WORD0X", 3), "Replacing at capacity is allowed")
    }

    @Test func messagesNeverQuoteWordsOrApps() {
        let errors: [DictionaryChangeError] = [.noVocabulary, .invalid(.empty), .full, .ignoreFull, .invalidKey, .appsFull,
                                               .unknownApp, .notSaved]
        for error in errors {
            #expect(!error.message.isEmpty && !error.message.contains("com.example") && !error.message.contains("Zorblax"))
        }
    }
}

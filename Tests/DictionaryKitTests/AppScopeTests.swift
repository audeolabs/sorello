import Foundation
import Testing
@testable import DictionaryKit

/// Words limited to apps (DESIGN §3.6). Every app, bundle identifier and word is invented.
struct AppScopeTests {
    let chat = DictionaryApp(id: "com.example.chat", name: "Chat")
    let mail = DictionaryApp(id: "com.example.mail", name: "Mail")
    let notes = DictionaryApp(id: "org.example.notes-2", name: "Notes")
    let editor = ScopedDictionaryEditor(encoder: testEncoder)

    private func k(_ text: String) -> DictionaryKey { DictionaryKey(text) }

    private func success(_ result: Result<ScopedDictionary, DictionaryChangeError>?,
                         sourceLocation: SourceLocation = #_sourceLocation) throws -> ScopedDictionary {
        guard case .success(let dictionary)? = result else {
            Issue.record("Expected a successful edit, got \(String(describing: result))", sourceLocation: sourceLocation)
            throw DictionaryChangeError.notSaved
        }
        return dictionary
    }

    private func apps() throws -> (chat: DictionaryApp, mail: DictionaryApp, notes: DictionaryApp) {
        (try #require(chat), try #require(mail), try #require(notes))
    }

    /// Chat and Mail known; "Zorbik" in Chat only, "Plexa" in Chat and Mail, "Kubernetes" everywhere.
    private func sample() throws -> ScopedDictionary {
        let (chat, mail, _) = try apps()
        var dictionary = try success(editor.registering(chat, in: ScopedDictionary()))
        dictionary = try success(editor.registering(mail, in: dictionary))
        dictionary = try success(editor.saving(text: "Kubernetes", strength: 1, apps: [], replacing: nil, in: dictionary))
        dictionary = try success(editor.saving(text: "Zorbik", strength: 2, apps: [chat.id], replacing: nil, in: dictionary))
        return try success(editor.saving(text: "Plexa", strength: 1.41, apps: [chat.id, mail.id], replacing: nil,
                                         in: dictionary))
    }

    @Test func appIdentity() {
        #expect(DictionaryApp(id: "com.example.chat", name: "Chat") != nil, "A bundle identifier")
        #expect(DictionaryApp(id: "org.example.notes-2", name: nil) != nil, "Digits and hyphens are allowed")
        for id in ["", "com.example chat", "com.example_chat", "com.exämple.chat", "com/example",
                   String(repeating: "a", count: DictionaryApp.maxIDLength + 1)] {
            #expect(DictionaryApp(id: id, name: "Chat") == nil, "Not a bundle identifier: \(id.debugDescription)")
        }
        #expect(DictionaryApp(id: String(repeating: "a", count: DictionaryApp.maxIDLength), name: "A") != nil,
                "155 characters is the longest identifier")
        #expect(DictionaryApp(id: "com.example.chat", name: "  Chat\n")?.name == "Chat")
        #expect(DictionaryApp(id: "com.example.chat", name: "Ch\u{7}at")?.name == "Chat")
        #expect(DictionaryApp(id: "com.example.chat", name: " \t ")?.name == "com.example.chat")
        #expect(DictionaryApp(id: "com.example.chat", name: nil)?.name == "com.example.chat")
        let long = DictionaryApp(id: "com.example.chat", name: String(repeating: "é", count: 150))
        #expect(long?.name.unicodeScalars.count == DictionaryApp.maxNameScalars)
    }

    @Test func scopes() throws {
        let (chat, mail, _) = try apps()
        let dictionary = try sample()
        #expect(dictionary.scopes.apps == [chat, mail])
        #expect(dictionary.scopes.apps(for: k("kubernetes")) == [])
        #expect(dictionary.scopes.apps(for: k("ZORBIK")) == [chat.id])
        #expect(dictionary.scopes.apps(for: k("plexa")) == [chat.id, mail.id])
        #expect(dictionary.applies(k("kubernetes"), in: nil), "An unlimited word applies without an app")
        #expect(dictionary.applies(k("kubernetes"), in: "com.example.other"), "and in any app")
        #expect(dictionary.applies(k("zorbik"), in: chat.id), "A limited word applies in its app")
        #expect(!dictionary.applies(k("zorbik"), in: mail.id), "but not in another app")
        #expect(!dictionary.applies(k("zorbik"), in: nil), "nor without an app")
        #expect(!dictionary.applies(k("absent"), in: chat.id), "A missing word applies nowhere")
        #expect(dictionary.scopes.wordCount(in: chat.id) == 2)
        #expect(dictionary.scopes.wordCount(in: mail.id) == 1)
        #expect(dictionary.scopes.wordCount(in: "com.example.other") == 0)
    }

    @Test func decodingWords() throws {
        let (chat, mail, notes) = try apps()
        let dictionary = try sample()
        func texts(_ appID: String?) -> [String] { dictionary.decodingWords(for: appID).entries.map(\.text) }
        #expect(texts(nil) == ["Kubernetes"])
        #expect(texts(chat.id) == ["Kubernetes", "Zorbik", "Plexa"])
        #expect(texts(mail.id) == ["Kubernetes", "Plexa"])
        #expect(texts("com.example.other") == ["Kubernetes"])
        #expect(dictionary.decodingWords(for: chat.id).entries.map(\.strength) == [1, 2, 1.41])
        // Only an app with limited words is recorded, so every other app shares the global graph.
        #expect(dictionary.decodingWords(for: chat.id).appID == chat.id)
        #expect(dictionary.decodingWords(for: "com.example.other").appID == nil)
        #expect(dictionary.decodingWords(for: nil).appID == nil)
        let unused = try success(editor.registering(notes, in: dictionary))
        #expect(unused.decodingWords(for: notes.id).appID == nil)
    }

    @Test func editing() throws {
        let (chat, mail, _) = try apps()
        var dictionary = try sample()
        #expect(editor.saving(text: "Quillon", strength: 1, apps: ["com.example.unknown"], replacing: nil, in: dictionary)
                == .failure(.unknownApp), "Apps must be known")
        #expect(editor.saving(text: "naïve—x", strength: 1, apps: [chat.id], replacing: nil, in: dictionary)
                == .failure(.invalid(.unencodable)), "Words are validated as before")

        // Saving sets the apps; an edit can widen, narrow or clear them.
        dictionary = try success(editor.saving(text: "Zorbik", strength: 2, apps: [chat.id, mail.id],
                                               replacing: k("zorbik"), in: dictionary))
        #expect(dictionary.scopes.apps(for: k("zorbik")) == [chat.id, mail.id])
        dictionary = try success(editor.saving(text: "Zorbik", strength: 2, apps: [], replacing: k("zorbik"), in: dictionary))
        #expect(dictionary.applies(k("zorbik"), in: nil), "No apps means everywhere")
        dictionary = try success(editor.saving(text: "Zorbik", strength: 2, apps: [mail.id], replacing: k("zorbik"),
                                               in: dictionary))
        #expect(dictionary.scopes.apps(for: k("zorbik")) == [mail.id])

        // A new text keeps the apps under the new key.
        dictionary = try success(editor.saving(text: "Zorbix", strength: 2, apps: [mail.id], replacing: k("zorbik"),
                                               in: dictionary))
        #expect(!dictionary.dictionary.contains(k("zorbik")), "The old entry is gone")
        #expect(dictionary.scopes.apps(for: k("zorbik")) == [])
        #expect(dictionary.scopes.apps(for: k("zorbix")) == [mail.id])

        // Removing an entry removes its apps; re-adding it starts everywhere.
        dictionary = try success(editor.removing(k("zorbix"), in: dictionary))
        #expect(dictionary.scopes.apps(for: k("zorbix")) == [])
        #expect(editor.removing(k("zorbix"), in: dictionary) == nil, "Nothing to remove")
        dictionary = try success(editor.saving(text: "Zorbix", strength: 1, apps: [], replacing: nil, in: dictionary))
        #expect(dictionary.applies(k("zorbix"), in: nil), "No stale limit survives a removal")

        // The ignore list stays global.
        dictionary = try success(editor.ignoring(k("eldar"), in: dictionary))
        #expect(dictionary.dictionary.isIgnored(k("eldar")), "Ignored")
        dictionary = try success(editor.unignoring(k("eldar"), in: dictionary))
        #expect(!dictionary.dictionary.isIgnored(k("eldar")), "Unignored")

        // One capacity across every app.
        var full = try success(editor.registering(chat, in: ScopedDictionary()))
        for index in 0..<DictionaryValidation.capacity {
            full = try success(editor.saving(text: "word\(index)x", strength: 1, apps: index.isMultiple(of: 2) ? [chat.id] : [],
                                             replacing: nil, in: full))
        }
        #expect(editor.saving(text: "overflow", strength: 1, apps: [chat.id], replacing: nil, in: full) == .failure(.full),
                "Limited words count toward the 1000 entries")
        #expect(editor.saving(text: "overflow", strength: 1, apps: [], replacing: nil, in: full) == .failure(.full),
                "and so do the others")
    }

    @Test func suggestionAdds() throws {
        let (chat, mail, notes) = try apps()
        let start = try sample()

        // Add to <App> with a new word limits it to that app.
        var dictionary = try success(editor.adding("Vantor", strength: 2, to: chat, in: start))
        #expect(dictionary.scopes.apps(for: k("vantor")) == [chat.id])
        #expect(dictionary.dictionary.entries.last == DictionaryEntry(text: "Vantor", strength: 2))

        // An unknown app is registered by the add, and a known one has its name updated.
        let renamed = try #require(DictionaryApp(id: chat.id, name: "Chat Pro"))
        dictionary = try success(editor.adding("Wexley", strength: 1, to: notes, in: dictionary))
        #expect(dictionary.scopes.app(id: notes.id) == notes)
        dictionary = try success(editor.adding("Yarrow", strength: 1, to: renamed, in: dictionary))
        #expect(dictionary.scopes.app(id: chat.id)?.name == "Chat Pro")
        #expect(dictionary.scopes.apps.map(\.id) == [chat.id, mail.id, notes.id])

        // An existing limited word gains the app, keeps its text and takes the higher strength.
        dictionary = try success(editor.adding("ZORBIK", strength: 1.41, to: mail, in: start))
        #expect(dictionary.scopes.apps(for: k("zorbik")) == [chat.id, mail.id])
        #expect(dictionary.dictionary.entries.first { $0.key == k("zorbik") } == DictionaryEntry(text: "Zorbik", strength: 2))
        dictionary = try success(editor.adding("zorbik", strength: 4, to: notes, in: dictionary))
        #expect(dictionary.dictionary.entries.first { $0.key == k("zorbik") }?.strength == 4)
        #expect(dictionary.scopes.apps(for: k("zorbik")) == [chat.id, mail.id, notes.id])

        // A word that already applies everywhere stays everywhere.
        dictionary = try success(editor.adding("Kubernetes", strength: 2, to: chat, in: start))
        #expect(dictionary.applies(k("kubernetes"), in: nil), "Still everywhere")
        #expect(dictionary.dictionary.entries.first { $0.key == k("kubernetes") }?.strength == 2)

        // Add everywhere: new words are unlimited, limited words become unlimited.
        dictionary = try success(editor.adding("Vantor", strength: 1, to: nil, in: start))
        #expect(dictionary.applies(k("vantor"), in: nil), "Added everywhere")
        dictionary = try success(editor.adding("plexa", strength: 1, to: nil, in: dictionary))
        #expect(dictionary.applies(k("plexa"), in: nil), "Widened to everywhere")
        #expect(dictionary.dictionary.entries.first { $0.key == k("plexa") } == DictionaryEntry(text: "Plexa", strength: 1.41))
        #expect(dictionary.scopes.apps == [chat, mail])

        #expect(editor.adding("naïve—x", strength: 1, to: chat, in: start) == .failure(.invalid(.unencodable)),
                "Suggested words are validated")
    }

    @Test func removingApps() throws {
        let (chat, mail, _) = try apps()
        var dictionary = try sample()
        dictionary = try success(editor.removingApp(chat.id, in: dictionary))
        #expect(dictionary.scopes.apps == [mail])
        #expect(!dictionary.dictionary.contains(k("zorbik")), "A word only in the removed app is removed, never made global")
        #expect(dictionary.scopes.apps(for: k("plexa")) == [mail.id])
        #expect(dictionary.applies(k("kubernetes"), in: nil), "Unlimited words stay")
        #expect(editor.removingApp(chat.id, in: dictionary) == nil, "Removing an unknown app changes nothing")
        dictionary = try success(editor.removingApp(mail.id, in: dictionary))
        #expect(dictionary.dictionary.entries.map(\.text) == ["Kubernetes"])
        #expect(dictionary.scopes.apps.isEmpty, "No apps left")
    }

    @Test func appCapacity() throws {
        var dictionary = ScopedDictionary()
        for index in 0..<DictionaryAppScopes.appCapacity {
            dictionary = try success(editor.registering(try #require(DictionaryApp(id: "com.example.app\(index)",
                                                                                   name: "App \(index)")), in: dictionary))
        }
        let extra = try #require(DictionaryApp(id: "com.example.extra", name: "Extra"))
        #expect(editor.registering(extra, in: dictionary) == .failure(.appsFull), "32 apps at most")
        #expect(editor.adding("Vantor", strength: 1, to: extra, in: dictionary) == .failure(.appsFull),
                "An add to a 33rd app is refused")
        let renamed = try #require(DictionaryApp(id: "com.example.app0", name: "Renamed"))
        dictionary = try success(editor.registering(renamed, in: dictionary))
        #expect(dictionary.scopes.app(id: renamed.id) == renamed)
        #expect(dictionary.scopes.apps.count == DictionaryAppScopes.appCapacity)
    }

    @Test func editsNeedVocabulary() throws {
        let (chat, _, notes) = try apps()
        let dictionary = try sample()
        let locked = ScopedDictionaryEditor(encoder: nil)
        #expect(!locked.canEdit, "No vocabulary, no edits")
        #expect(locked.saving(text: "Vantor", strength: 1, apps: [chat.id], replacing: nil, in: dictionary)
                == .failure(.noVocabulary))
        #expect(locked.removing(k("zorbik"), in: dictionary) == .failure(.noVocabulary))
        #expect(locked.adding("Vantor", strength: 1, to: chat, in: dictionary) == .failure(.noVocabulary))
        #expect(locked.registering(notes, in: dictionary) == .failure(.noVocabulary))
        #expect(locked.removingApp(chat.id, in: dictionary) == .failure(.noVocabulary))
        #expect(locked.ignoring(k("eldar"), in: dictionary) == .failure(.noVocabulary))
        #expect(locked.unignoring(k("eldar"), in: dictionary) == .failure(.noVocabulary))
    }

    /// The store hands out the words for a dictation's app, tagged with the revision they came from.
    @Test func storeSnapshots() throws {
        let (chat, mail, _) = try apps()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictionaryStore(fileURL: directory.appendingPathComponent("dictionary.json"), encoder: testEncoder)
        #expect(store.snapshot(for: chat.id).entries.isEmpty)
        try store.register(chat)
        try store.save(text: "Kubernetes", strength: 1)
        try store.save(text: "Zorbik", strength: 2, apps: [chat.id])
        let inChat = store.snapshot(for: chat.id)
        #expect(inChat == DictionarySnapshot(revision: store.revision, entries: [entry("Kubernetes"), entry("Zorbik", 2)],
                                             appID: chat.id))
        #expect(store.snapshot(for: mail.id) == DictionarySnapshot(revision: store.revision, entries: [entry("Kubernetes")]))
        #expect(store.snapshot(for: nil).appID == nil)

        try store.add("Plexa", strength: 1.41, to: mail)
        #expect(store.snapshot(for: mail.id).appID == mail.id, "Adding to an app registers it")
        #expect(store.snapshot(for: mail.id).revision > inChat.revision, "A change makes earlier snapshots older")
        #expect(try store.removeApp(id: chat.id))
        #expect(!store.dictionary.dictionary.contains(k("zorbik")), "A word only in the removed app is removed")
        #expect(try store.removeApp(id: chat.id) == false)
    }
}

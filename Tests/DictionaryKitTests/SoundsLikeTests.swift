import Foundation
import Testing
@testable import DictionaryKit

/// Sounds-like spellings (DESIGN §3.7): what they may be, that a key means one thing, that edits keep them, that they
/// are boosted with their entry, and that a written spelling becomes its entry. All words are invented.
struct SoundsLikeTests {
    private func spellings(_ list: [String], word: String = "Sorello",
                           encoder: BPEEncoder? = testEncoder) -> Result<[String], SoundsLikeError> {
        SoundsLike.validate(list, word: word, encoder: encoder)
    }

    @Test func validation() {
        #expect(SoundsLike.maxSpellings == 4)
        // Normalized as entries are, in the user's order.
        #expect(spellings(["  so   rello ", "Sarello"]) == .success(["so rello", "Sarello"]))
        #expect(spellings([]) == .success([]))
        // A repeat by key is one spelling: the first is kept, and repeats do not count toward the limit.
        #expect(spellings(["Sarello", "sarello", "SARELLO", "Cerello", "Zarello", "Serrello"])
                == .success(["Sarello", "Cerello", "Zarello", "Serrello"]))
        #expect(spellings(["Sarello", "Cerello", "Zarello", "Serrello", "Sorrelo"]) == .failure(.tooMany))
        // The word itself, by key, is not a spelling of it.
        #expect(spellings(["sorello"]) == .failure(.sameAsWord))
        #expect(spellings(["SORELLO"], word: "Sorello") == .failure(.sameAsWord))
        // §1.1's text rules, steps 1 to 3.
        #expect(spellings(["  "]) == .failure(.invalid(.empty)))
        #expect(spellings(["a b c d e f g h i"]) == .failure(.invalid(.tooManyWords)))
        #expect(spellings([String(repeating: "a", count: 101)]) == .failure(.invalid(.tooLong)))
        #expect(spellings(["1234"]) == .failure(.invalid(.noLetter)))
        #expect(spellings(["s\u{7}rello"], encoder: nil) == .failure(.invalid(.unencodable)))
        #expect(spellings(["sörello"]) == .failure(.invalid(.unencodable)), "Not in the test vocabulary")
        #expect(spellings(["sörello"], encoder: nil) == .success(["sörello"]), "Without a vocabulary, not checked")
        // Settings separates spellings with commas, so none can hold one.
        #expect(spellings(["so, rello"]) == .failure(.comma))
    }

    @Test func settingsSeparatesSpellingsWithCommas() {
        #expect(SoundsLike.parse("Sarello, so rello") == ["Sarello", "so rello"])
        #expect(SoundsLike.parse(" , Sarello,,  ,so   rello ,") == ["Sarello", "so   rello"])
        #expect(SoundsLike.parse("") == [])
        #expect(SoundsLike.parse("   ") == [])
    }

    @Test func errorsNeverQuoteASpelling() {
        let errors: [SoundsLikeError] = [.invalid(.empty), .invalid(.tooManyWords), .invalid(.tooLong),
                                         .invalid(.noLetter), .invalid(.unencodable), .comma, .sameAsWord, .tooMany,
                                         .taken]
        #expect(Set(errors.map(\.message)).count == errors.count, "Each says something different")
        #expect(SoundsLikeError.tooMany.message.contains("4"))
        let changes: [DictionaryChangeError] = [.soundsLike(.taken), .spellingOfAnotherWord]
        #expect(Set(changes.map(\.message)).count == 2)
        #expect(!DictionaryChangeError.spellingOfAnotherWord.message.isEmpty)
    }

    @Test func oneKeyOneMeaning() throws {
        let editor = DictionaryEditor(encoder: testEncoder)
        var dictionary = try editor.saving(text: "Sorello", strength: 1, soundsLike: ["Sarello", "so rello"],
                                           replacing: nil, in: CustomDictionary()).get()
        dictionary = try editor.saving(text: "Kestrova", strength: 2, soundsLike: ["Castrova"], replacing: nil,
                                       in: dictionary).get()
        #expect(dictionary.entries.map(\.soundsLike) == [["Sarello", "so rello"], ["Castrova"]])

        // A spelling may not be another entry's key, nor another entry's spelling, whatever its case.
        #expect(editor.saving(text: "Kestrova", strength: 2, soundsLike: ["sorello"], replacing: nil,
                              in: dictionary).failure == .soundsLike(.taken))
        #expect(editor.saving(text: "Kestrova", strength: 2, soundsLike: ["SARELLO"], replacing: nil,
                              in: dictionary).failure == .soundsLike(.taken))
        #expect(editor.saving(text: "Plexa", strength: 1, soundsLike: ["so rello"], replacing: nil,
                              in: dictionary).failure == .soundsLike(.taken))
        // An entry may not be another entry's spelling.
        #expect(editor.saving(text: "sarello", strength: 1, replacing: nil, in: dictionary).failure
                == .spellingOfAnotherWord)
        #expect(editor.saving(text: "Castrova", strength: 1, soundsLike: [], replacing: nil, in: dictionary).failure
                == .spellingOfAnotherWord)
        // Saving an entry again with its own spellings is no conflict with itself.
        let again = try editor.saving(text: "Sorello", strength: 4, soundsLike: ["Sarello", "so rello"],
                                      replacing: nil, in: dictionary).get()
        #expect(again.entries.map(\.strength) == [4, 2])
        // A spelling given up by one entry is free for another.
        let freed = try editor.saving(text: "Sorello", strength: 1, soundsLike: ["so rello"], replacing: nil,
                                      in: dictionary).get()
        let taken = try editor.saving(text: "Plexa", strength: 1, soundsLike: ["Sarello"], replacing: nil,
                                      in: freed).get()
        #expect(taken.entries.map(\.soundsLike) == [["so rello"], ["Castrova"], ["Sarello"]])
        // A removed entry's spellings are free too.
        let removed = try #require(editor.removing(DictionaryKey("Sorello"), in: dictionary)).get()
        #expect(editor.saving(text: "Sarello", strength: 1, replacing: nil, in: removed).isSuccess)

        // A dictionary that breaks the rule could not have been saved.
        #expect(CustomDictionary(entries: [DictionaryEntry(text: "Sorello", strength: 1, soundsLike: ["Sarello"]),
                                           DictionaryEntry(text: "Sarello", strength: 1)], ignore: []) == nil)
        #expect(CustomDictionary(entries: [DictionaryEntry(text: "Sorello", strength: 1, soundsLike: ["Sarello"]),
                                           DictionaryEntry(text: "Plexa", strength: 1, soundsLike: ["sarello"])],
                                 ignore: []) == nil)
        #expect(CustomDictionary(entries: [DictionaryEntry(text: "Sorello", strength: 1, soundsLike: ["Sarello"]),
                                           DictionaryEntry(text: "Plexa", strength: 1, soundsLike: ["Plaxa"])],
                                 ignore: []) != nil)
    }

    @Test func spellingsAreCheckedWhenSaved() {
        let editor = DictionaryEditor(encoder: testEncoder)
        // The entry's own text comes first, then its spellings.
        #expect(editor.saving(text: "1234", strength: 1, soundsLike: ["so, rello"], replacing: nil,
                              in: CustomDictionary()).failure == .invalid(.noLetter))
        #expect(editor.saving(text: "Sorello", strength: 1, soundsLike: ["so, rello"], replacing: nil,
                              in: CustomDictionary()).failure == .soundsLike(.comma))
        #expect(editor.saving(text: "Sorello", strength: 1, soundsLike: ["SORELLO"], replacing: nil,
                              in: CustomDictionary()).failure == .soundsLike(.sameAsWord))
        #expect(DictionaryEditor(encoder: nil).saving(text: "Sorello", strength: 1, soundsLike: ["Sarello"],
                                                      replacing: nil, in: CustomDictionary()).failure
                == .noVocabulary)
    }

    @Test func editsKeepSpellings() throws {
        let editor = DictionaryEditor(encoder: testEncoder)
        let base = try editor.saving(text: "Sorello", strength: 1, soundsLike: ["Sarello"], replacing: nil,
                                     in: CustomDictionary()).get()
        // Without spellings given, a save keeps the entry's; the iPhone app's edits call it so.
        let stronger = try editor.saving(text: "Sorello", strength: 2, replacing: DictionaryKey("Sorello"),
                                         in: base).get()
        #expect(stronger.entries == [DictionaryEntry(text: "Sorello", strength: 2, soundsLike: ["Sarello"])])
        let sameKey = try editor.saving(text: "sorello", strength: 1, replacing: nil, in: base).get()
        #expect(sameKey.entries.map(\.soundsLike) == [["Sarello"]], "The entry the save replaces keeps them")
        // A new text keeps them under its new key, checked against it.
        let renamed = try editor.saving(text: "Sorelo", strength: 1, replacing: DictionaryKey("Sorello"),
                                        in: base).get()
        #expect(renamed.entries == [DictionaryEntry(text: "Sorelo", strength: 1, soundsLike: ["Sarello"])])
        #expect(editor.saving(text: "Sarello", strength: 1, replacing: DictionaryKey("Sorello"), in: base).failure
                == .soundsLike(.sameAsWord))
        // Given, they replace what it had; empty removes them.
        let cleared = try editor.saving(text: "Sorello", strength: 1, soundsLike: [], replacing: nil, in: base).get()
        #expect(cleared.entries.map(\.soundsLike) == [[]])

        // A suggestion's Add for a word already there keeps its spellings, with or without an app.
        var scoped = ScopedDictionary()
        scoped.dictionary = base
        let chat = try #require(DictionaryApp(id: "com.example.chat", name: "Chat"))
        let scopedEditor = ScopedDictionaryEditor(encoder: testEncoder)
        for app in [chat, nil] as [DictionaryApp?] {
            let added = try scopedEditor.adding("sorello", strength: 2.83, to: app, in: scoped).get()
            #expect(added.dictionary.entries == [DictionaryEntry(text: "Sorello", strength: 2.83,
                                                                 soundsLike: ["Sarello"])])
        }
        // A suggestion of a word that is a spelling would be refused.
        #expect(scopedEditor.adding("Sarello", strength: 1, to: nil, in: scoped).failure == .spellingOfAnotherWord)
        // Changing apps keeps them.
        let limited = try scopedEditor.saving(text: "Sorello", strength: 1, apps: [], replacing: DictionaryKey("Sorello"),
                                              in: scoped).get()
        #expect(limited.dictionary.entries.map(\.soundsLike) == [["Sarello"]])
    }

    @Test func storeEditsKeepSpellings() throws {
        let scratch = StoreTests.Scratch()
        let store = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        try store.save(text: "Sorello", strength: 1, soundsLike: ["Sarello", "so rello"])
        try store.save(text: "Sorello", strength: 2, replacing: DictionaryKey("Sorello"))
        #expect(store.dictionary.dictionary.entries
                == [DictionaryEntry(text: "Sorello", strength: 2, soundsLike: ["Sarello", "so rello"])])
        let revision = store.revision
        try store.save(text: "Sorello", strength: 2, soundsLike: ["Sarello", "so rello"],
                       replacing: DictionaryKey("Sorello"))
        #expect(store.revision == revision, "The same spellings change nothing")
        try store.save(text: "Sorello", strength: 2, soundsLike: ["so rello"], replacing: DictionaryKey("Sorello"))
        #expect(store.revision == revision + 1, "Other spellings are a change")
        #expect(store.snapshot(for: nil).entries.map(\.soundsLike) == [["so rello"]], "Decoding sees them")
        let reopened = DictionaryStore(fileURL: scratch.file, encoder: testEncoder)
        #expect(reopened.opening == .loaded)
        #expect(reopened.dictionary == store.dictionary, "They are saved")
        #expect(throws: DictionaryChangeError.soundsLike(.tooMany)) {
            try store.save(text: "Sorello", strength: 2, soundsLike: ["a", "b", "c", "d", "e"])
        }
    }

    @Test func spellingsAreBoosted() {
        let plain = BiasGraph.phrases(entries: [entry("Zorbik", 2)], encoder: testEncoder)
        let withSpellings = BiasGraph.phrases(
            entries: [DictionaryEntry(text: "Zorbik", strength: 2, soundsLike: ["zor bick", "Sorbik"])],
            encoder: testEncoder)
        // The entry's own surfaces first, unchanged; then each spelling's surfaces, at the entry's strength.
        let expected = (BiasGraph.surfaces(of: "Zorbik") + BiasGraph.surfaces(of: "zor bick")
                        + BiasGraph.surfaces(of: "Sorbik")).map { testEncoder.encode(DictionaryText.string($0)) }
        var unique: [[Int]] = []
        for tokens in expected where !unique.contains(tokens) { unique.append(tokens) }
        #expect(withSpellings.map(\.tokens) == unique)
        #expect(withSpellings.allSatisfy { $0.strength == 2 })
        #expect(Array(withSpellings.prefix(plain.count)).map(\.tokens) == plain.map(\.tokens))
        // Built, a spelling's path earns a bonus.
        let graph = BiasGraph.build(entries: [DictionaryEntry(text: "Zorbik", strength: 2, soundsLike: ["Sorbik"])],
                                    encoder: testEncoder)
        let path = testEncoder.encode("Sorbik")
        var state = BiasGraph.root
        var bonus: Float = 0
        for token in path { (state, bonus) = graph?.step(state, token) ?? (state, 0) }
        #expect(bonus > 0, "The spelling's last token is boosted")
    }

    @Test func replacement() {
        let sorello = DictionaryEntry(text: "Sorello", strength: 1, soundsLike: ["Sarello", "so rello"])
        func apply(_ text: String, _ entries: [DictionaryEntry] = [sorello]) -> String {
            TranscriptRestorer.apply(text, entries: entries)
        }
        expectScalars(apply("ask sarello about it"), "ask Sorello about it")
        expectScalars(apply("Sarello, then SO RELLO."), "Sorello, then Sorello.")
        expectScalars(apply("so rello"), "Sorello")
        // Whole words only.
        expectScalars(apply("sarellos and isarello"), "sarellos and isarello")
        expectScalars(apply("so rellotta"), "so rellotta")
        expectScalars(apply("(sarello)"), "(Sorello)")
        // A run of spaces is not the one the spelling has.
        expectScalars(apply("so  rello"), "so  rello")
        // Longest first: a longer spelling of another entry wins where both start.
        let rello = DictionaryEntry(text: "Rellux", strength: 1, soundsLike: ["rello"])
        expectScalars(apply("so rello and rello", [rello, sorello]), "Sorello and Rellux")
        // The replacement is not scanned again: "Vel ora" would be Quix's spelling.
        let vel = DictionaryEntry(text: "Vel", strength: 1, soundsLike: ["bell"])
        let quix = DictionaryEntry(text: "Quix", strength: 1, soundsLike: ["vel ora"])
        expectScalars(apply("bell ora", [vel, quix]), "Vel ora")
        expectScalars(apply("vel ora", [vel, quix]), "Quix")
        // Then casing is restored (§1.4), so an entry written in lower case and a spelling both come out right.
        let nix = DictionaryEntry(text: "NixOS", strength: 1, soundsLike: ["nix o s"])
        expectScalars(apply("nix o s and nixos", [nix]), "NixOS and NixOS")
        // Without spellings, this is casing restoration alone.
        for text in ["i installed nixos", "Iphone is new", "sarello"] {
            let entries = [entry("NixOS"), entry("iPhone"), entry("Sorello")]
            expectScalars(apply(text, entries), CasingRestorer.apply(text, entries: entries))
        }
        expectScalars(apply("anything at all", []), "anything at all")
    }
}

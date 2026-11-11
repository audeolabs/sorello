import DictionaryKit
import Foundation
import Testing

/// What another app can do with the dictionary through the module's public interface alone (ARCHITECTURE.md, section
/// 13). The iPhone app keeps its dictionary in a store of its own, so it edits one with the shared editor and rebuilds
/// one from what it saved, and has no copy of the rules. This file imports the module as that app does, not
/// `@testable`, so everything it names is public. All words are invented.
struct PublicEditingTests {
    let editor = DictionaryEditor(encoder: testEncoder)

    /// Adding, editing and removing go through the editor, which validates first and returns the proposed state.
    @Test func theEditorAddsEditsAndRemoves() throws {
        let added = try editor.saving(text: "Zorblax", strength: 1, replacing: nil, in: CustomDictionary()).get()
        #expect(added.entries == [DictionaryEntry(text: "Zorblax", strength: 1)])
        // The same word in another case is the same entry: it takes its place.
        let stronger = try editor.saving(text: "zorblax", strength: 2, replacing: nil, in: added).get()
        #expect(stronger.entries == [DictionaryEntry(text: "zorblax", strength: 2)])
        // Editing an entry into another word removes the word it was.
        let renamed = try editor.saving(text: "Quint", strength: 2, replacing: DictionaryKey("zorblax"),
                                        in: stronger).get()
        #expect(renamed.entries == [DictionaryEntry(text: "Quint", strength: 2)])
        #expect(!renamed.contains(DictionaryKey("zorblax")) && renamed.contains(DictionaryKey("QUINT")))
        let removed = try #require(editor.removing(DictionaryKey("quint"), in: renamed)).get()
        #expect(removed.entries.isEmpty)
        #expect(editor.removing(DictionaryKey("quint"), in: removed) == nil, "Nothing to remove")
    }

    /// A word that cannot be an entry is refused with the reason.
    @Test func theEditorRefusesWhatCannotBeAnEntry() {
        #expect(editor.saving(text: "", strength: 1, replacing: nil, in: CustomDictionary()).failure
            == .invalid(.empty))
        #expect(editor.saving(text: "Zorblax", strength: 9, replacing: nil, in: CustomDictionary()).failure
            == .invalid(.invalidStrength))
    }

    /// Without the speech model's vocabulary nothing may change: an entry cannot be checked.
    @Test func withoutAVocabularyNothingChanges() throws {
        let locked = DictionaryEditor(encoder: nil)
        #expect(!locked.canEdit && editor.canEdit)
        let dictionary = try #require(CustomDictionary(entries: [DictionaryEntry(text: "Zorblax", strength: 1)],
                                                       ignore: []))
        #expect(locked.saving(text: "Quint", strength: 1, replacing: nil, in: dictionary).failure == .noVocabulary)
        #expect(locked.removing(DictionaryKey("zorblax"), in: dictionary)?.failure == .noVocabulary)
        #expect(locked.ignoring(DictionaryKey("blorf"), in: dictionary).failure == .noVocabulary)
        #expect(locked.unignoring(DictionaryKey("blorf"), in: dictionary)?.failure == .noVocabulary)
    }

    /// The dictionary is full at its capacity; an entry that is already there can still be changed.
    @Test func aFullDictionaryTakesNoNewEntry() throws {
        let entries = (0 ..< DictionaryValidation.capacity).map { DictionaryEntry(text: "word\($0)x", strength: 1) }
        let full = try #require(CustomDictionary(entries: entries, ignore: []))
        #expect(editor.saving(text: "overflow", strength: 1, replacing: nil, in: full).failure == .full)
        #expect(editor.saving(text: "WORD0X", strength: 3, replacing: nil, in: full).isSuccess)
    }

    /// The ignore list is edited the same way; ignoring a key twice changes nothing.
    @Test func theEditorIgnoresAndUnignores() throws {
        let ignored = try editor.ignoring(DictionaryKey("Blorf"), in: CustomDictionary()).get()
        #expect(ignored.ignore == [DictionaryKey("blorf")] && ignored.isIgnored(DictionaryKey("BLORF")))
        let again = try editor.ignoring(DictionaryKey("blorf"), in: ignored).get()
        #expect(again == ignored)
        let cleared = try #require(editor.unignoring(DictionaryKey("blorf"), in: ignored)).get()
        #expect(cleared.ignore.isEmpty)
        #expect(editor.unignoring(DictionaryKey("blorf"), in: cleared) == nil, "The key is not ignored")
    }

    /// A store of its own rebuilds the dictionary from what it saved, in the order it was saved.
    @Test func aSavedDictionaryIsRebuiltInOrder() throws {
        let entries = [DictionaryEntry(text: "Zorblax", strength: 1),
                       DictionaryEntry(text: "Quint Morrow", strength: 2.83),
                       DictionaryEntry(text: "Vellum", strength: 0.5)]
        let ignore = [DictionaryKey("blorf"), DictionaryKey("snee wobble")]
        let dictionary = try #require(CustomDictionary(entries: entries, ignore: ignore))
        #expect(dictionary.entries == entries)
        #expect(dictionary.ignore == ignore)
        #expect(dictionary.contains(DictionaryKey("VELLUM")) && dictionary.isIgnored(DictionaryKey("Snee Wobble")))
        #expect(CustomDictionary(entries: [], ignore: []) == CustomDictionary())
    }

    /// What could not have been saved is refused whole, so a store never loads half a dictionary: an entry or a key
    /// that repeats, one whose key is not valid, or more than the dictionary holds.
    @Test func whatCouldNotHaveBeenSavedIsRefused() {
        let zorblax = DictionaryEntry(text: "Zorblax", strength: 1)
        #expect(CustomDictionary(entries: [zorblax, DictionaryEntry(text: "zorblax", strength: 2)], ignore: []) == nil,
                "The same word twice")
        #expect(CustomDictionary(entries: [DictionaryEntry(text: "", strength: 1)], ignore: []) == nil, "No key")
        let tooMany = (0 ... DictionaryValidation.capacity).map { DictionaryEntry(text: "word\($0)x", strength: 1) }
        #expect(CustomDictionary(entries: tooMany, ignore: []) == nil, "One more than the dictionary holds")
        #expect(CustomDictionary(entries: Array(tooMany.dropLast()), ignore: []) != nil, "Exactly what it holds")

        let blorf = DictionaryKey("blorf")
        #expect(CustomDictionary(entries: [], ignore: [blorf, DictionaryKey("BLORF")]) == nil, "The same key twice")
        #expect(CustomDictionary(entries: [], ignore: [DictionaryKey("")]) == nil, "An empty key")
        #expect(CustomDictionary(entries: [], ignore: [DictionaryKey("a\u{7}b")]) == nil, "A control character")
        #expect(CustomDictionary(entries: [], ignore: [DictionaryKey("a b c d e f g h i")]) == nil, "Nine words")
        let keys = (0 ... DictionaryValidation.ignoreCapacity).map { DictionaryKey("w\($0)") }
        #expect(CustomDictionary(entries: [], ignore: keys) == nil, "One more than the ignore list holds")
        #expect(CustomDictionary(entries: [], ignore: Array(keys.dropLast())) != nil, "Exactly what it holds")
    }
}

import Foundation
import Testing
@testable import DictionaryKit

/// Text units, encoding, validation and the dictionary's own rules (DESIGN §1.0, §1.1, §1.3, pins P4, P6, P7).
struct EntryTests {
    @Test func textUnits() {
        // Full lowercase mapping: one scalar can fold to two.
        #expect(DictionaryText.fold(s("İX")) == s("i\u{307}x"), "fold must use the full lowercase mapping")
        #expect(DictionaryText.fold(s("NixOS")) == s("nixos"), "fold lowercases every scalar")
        #expect(DictionaryText.upper1(s("ßtraße")) == s("SStraße"), "upper1 maps only the first scalar, fully")
        #expect(DictionaryText.upper1(s("")) == [], "upper1 of empty is empty")
        // Canonically equivalent strings stay distinct: identity is by scalars.
        #expect(DictionaryText.fold(s("e\u{301}")) != DictionaryText.fold(s("é")), "No normalization is applied")
        for scalar in s("aZé_\u{301}5") {
            #expect(DictionaryText.isWordCharacter(scalar), "\(scalar) is a word character")
        }
        for scalar in s(" -#+/@.'") {
            #expect(!DictionaryText.isWordCharacter(scalar), "\(scalar) is not a word character")
        }
        #expect(DictionaryText.isWhitespace("\u{3000}") && DictionaryText.isWhitespace("\n"), "White_Space")
        #expect(DictionaryText.norm(s("«Kubernetes!»")) == s("kubernetes"), "norm strips edge punctuation")
        #expect(DictionaryText.norm(s("C#")) == s("c#"), "Technical symbols are kept")
        #expect(DictionaryText.norm(s("—")) == [], "Pure edge punctuation norms to empty")
        #expect(DictionaryText.words(s(" a\tb\u{3000}c \n")) == [s("a"), s("b"), s("c")], "Words split on any whitespace")
    }

    @Test func encoderHandCases() {
        let encoder = BPEEncoder(pieces: ["<unk>", "▁t", "he", "▁the", "▁", "t", "h", "e", "c", "a", "at", "▁c", "aa"])
        // ▁ t h e ▁ c a t → ▁t, he, ▁the, at, ▁c: lowest id merges first.
        #expect(encoder.encode("the cat") == [3, 11, 10])
        // Equal pairs merge leftmost first.
        #expect(encoder.encode("aaa") == [4, 12, 9])
        // A run of non-pieces is one <unk> (P4); separated runs are separate.
        #expect(encoder.encode("tzzh") == [1, 0, 6])
        #expect(encoder.encode("tzhz") == [1, 0, 6, 0])
        // P7: the dummy prefix applies to empty text too, so "" encodes as "▁".
        #expect(encoder.encode("") == [4])
        #expect(!encoder.encodesWithoutUnknown("tz"), "<unk> makes text unencodable")
        #expect(encoder.encodesWithoutUnknown("the cat"), "Known pieces encode")
        // Pieces are matched by exact scalars: a decomposed é is not the precomposed piece.
        let accents = BPEEncoder(pieces: ["<unk>", "▁", "é"])
        #expect(accents.encode("é") == [1, 2])
        #expect(accents.encode("e\u{301}") == [1, 0])
        // Duplicate pieces keep their lowest id; <unk> itself is never produced from text.
        let duplicate = BPEEncoder(pieces: ["<unk>", "▁", "x", "x", "<", "u", "n", "k", ">"])
        #expect(duplicate.encode("x") == [1, 2])
    }

    @Test func vocabularyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        var object = Dictionary(uniqueKeysWithValues: (0..<1024).map { (String($0), "p\($0)") })
        object["0"] = "<unk>"
        object["1"] = "▁"
        object["2"] = "z"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let encoder = try BPEEncoder(vocabularyFile: url)
        #expect(encoder.encode("z") == [1, 2])

        object.removeValue(forKey: "1023")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: VocabularyError.self) { try BPEEncoder(vocabularyFile: url) }
        #expect(throws: VocabularyError.self) { try BPEEncoder(vocabularyFile: directory.appendingPathComponent("none")) }
    }

    @Test func validation() throws {
        func validate(_ text: String, _ strength: Float = 1) -> Result<DictionaryEntry, DictionaryEntryError> {
            DictionaryValidation.validate(text: text, strength: strength, encoder: testEncoder)
        }
        let valid = try validate("  New\t\u{3000}York  ").get()
        expectScalars(valid.text, "New York")
        #expect(validate("") == .failure(.empty), "Empty text")
        #expect(validate(" \n ") == .failure(.empty), "Whitespace-only text")
        #expect(validate("a b c d e f g h").isSuccess, "Eight words are allowed")
        #expect(validate("a b c d e f g h i") == .failure(.tooManyWords), "Nine words are not")
        #expect(validate(String(repeating: "a", count: 100)).isSuccess, "100 scalars are allowed")
        #expect(validate(String(repeating: "a", count: 101)) == .failure(.tooLong), "101 scalars are not")
        // Scalars, not characters: graphemes of two scalars each.
        #expect(validate(String(repeating: "e\u{301}", count: 51)) == .failure(.tooLong), "Limits count scalars")
        #expect(validate("12 34") == .failure(.noLetter), "At least one letter")
        #expect(validate("naïve—x") == .failure(.unencodable), "Unencodable text")
        #expect(validate("C#", 0.25).isSuccess && validate("C#", 8).isSuccess, "Strength bounds are inclusive")
        for bad: Float in [0.24, 8.01, .nan, .infinity, -1] {
            #expect(validate("C#", bad) == .failure(.invalidStrength), "Strength \(bad) is invalid")
        }
        // Without a vocabulary the encodability check cannot run; the rest still applies.
        #expect(DictionaryValidation.validate(text: "naïve—x", strength: 1, encoder: nil).isSuccess,
                "No vocabulary skips only the encodability check")
        #expect(DictionaryValidation.presets == [0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8])
        #expect(DictionaryValidation.label(1.41) == "×1.41" && DictionaryValidation.label(2) == "×2"
                && DictionaryValidation.label(0.5) == "×0.5")
    }

    @Test func errorsNeverQuoteTheEntry() {
        let errors: [DictionaryEntryError] = [.empty, .tooManyWords, .tooLong, .noLetter, .unencodable, .invalidStrength]
        for error in errors {
            #expect(!error.message.isEmpty && !error.message.contains("Zorblax"))
        }
        #expect(DictionaryEntryError.tooManyWords.rawValue == "too-many-words")
        #expect(DictionaryEntryError.invalidStrength.rawValue == "bad-strength")
    }

    @Test func dictionaryRules() {
        var dictionary = CustomDictionary()
        #expect({ dictionary.upsert(entry("NixOS")) }() == nil, "Add")
        #expect({ dictionary.upsert(entry("nixos", 2)) }() == nil, "Same key replaces")
        #expect(dictionary.entries.count == 1)
        expectScalars(dictionary.entries[0].text, "nixos")
        #expect(dictionary.entries[0].strength == 2)
        #expect(dictionary.contains(DictionaryKey("NIXOS")), "Identity is the folded text")
        #expect(!dictionary.contains(DictionaryKey("nixos ")), "Identity compares exact scalars")
        #expect({ dictionary.remove(DictionaryKey("NixOS")) }(), "Remove by key")
        #expect(!{ dictionary.remove(DictionaryKey("NixOS")) }(), "Removing twice reports not found")

        for index in 0..<DictionaryValidation.capacity {
            #expect({ dictionary.upsert(entry("word\(index)x")) }() == nil, "Within capacity")
        }
        #expect({ dictionary.upsert(entry("overflow")) }() == .full, "Capacity is 1000 entries")
        #expect({ dictionary.upsert(entry("WORD0X", 3)) }() == nil, "Replacing at capacity is allowed")

        var ignore = CustomDictionary()
        #expect({ ignore.addIgnore(DictionaryKey("Eldar")) }() == nil, "Ignore")
        #expect({ ignore.addIgnore(DictionaryKey("eldar")) }() == nil, "Ignoring twice is idempotent")
        #expect(ignore.ignore.count == 1)
        for index in 1..<DictionaryValidation.ignoreCapacity {
            #expect({ ignore.addIgnore(DictionaryKey("w\(index)")) }() == nil, "Within ignore capacity")
        }
        #expect({ ignore.addIgnore(DictionaryKey("one more")) }() == .full, "Ignore capacity is 1000")
        #expect({ ignore.removeIgnore(DictionaryKey("ELDAR")) }(), "Unignore by key")
    }

    /// Pin P6: keys are checked on load and before saving, with limits of their own.
    @Test func keyValidity() throws {
        // A valid 100-scalar surface whose key folds to 101 scalars.
        let entry = try DictionaryValidation.validate(text: "İ" + String(repeating: "a", count: 99), strength: 1,
                                                      encoder: nil).get()
        let key = entry.key
        #expect(key.scalars.count == 101)
        #expect(key.isValid, "Keys of valid surfaces are valid")
        // "Don't suggest" then restart: the dictionary must still load.
        var scoped = ScopedDictionary()
        #expect({ scoped.dictionary.addIgnore(key) }() == nil, "Ignoring the key")
        #expect({ scoped.dictionary.upsert(entry) }() == nil, "Adding the entry")
        let reloaded = try #require(DictionaryFile.decode(DictionaryFile.encode(scoped), encoder: nil),
                                    "A saved ignore key must never make the file unreadable")
        #expect(reloaded == scoped && reloaded.dictionary.isIgnored(key), "Ignore key round-trips")

        #expect(DictionaryKey(folded: s(String(repeating: "a", count: 300))).isValid, "300 scalars")
        #expect(DictionaryKey(folded: s("a b c d e f g h")).isValid, "Eight words")
        let invalid: [[Unicode.Scalar]] = [
            [], s(String(repeating: "a", count: 301)), s("a b c d e f g h i"), s("a\u{7}b"), s("a\tb"), s("Eldar"),
        ]
        for scalars in invalid {
            var probe = CustomDictionary()
            #expect(!DictionaryKey(folded: scalars).isValid, "Invalid key \(scalars)")
            #expect({ probe.addIgnore(DictionaryKey(folded: scalars)) }() == .invalidKey, "Never saved")
            #expect(DictionaryFile.decode(fileData(ignore: [DictionaryText.string(scalars)]), encoder: nil) == nil,
                    "Never loaded")
        }
        // A control scalar is unencodable (§1.1), with or without a vocabulary.
        #expect(DictionaryValidation.validate(text: "a\u{7}b", strength: 1, encoder: nil) == .failure(.unencodable))
        #expect(DictionaryValidation.validate(text: "a\u{7}b", strength: 1, encoder: testEncoder) == .failure(.unencodable))
    }
}

/// A dictionary file with these parts, encoded as JSON the way any writer might.
func fileData(entries: [[String: Any]] = [], ignore: [String] = [], apps: [[String: Any]] = [],
              version: Int = 1) -> Data {
    let object: [String: Any] = ["version": version, "entries": entries, "ignore": ignore, "apps": apps]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

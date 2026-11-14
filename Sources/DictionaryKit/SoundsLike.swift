import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// Why an entry's spellings cannot be saved (DESIGN §3.7). Messages never quote a spelling.
public enum SoundsLikeError: Error, Equatable, Sendable {
    /// A spelling breaks one of §1.1's rules for text.
    case invalid(DictionaryEntryError)
    /// Settings separates spellings with commas, so a spelling cannot hold one.
    case comma
    /// A spelling is the entry's own word.
    case sameAsWord
    /// More than `SoundsLike.maxSpellings`.
    case tooMany
    /// A spelling is another entry's word or one of its spellings.
    case taken

    public var message: String {
        switch self {
        case .invalid(.empty): return String(localized: "A spelling can’t be empty.")
        case .invalid(.tooManyWords):
            return String(localized: "Use at most \(DictionaryValidation.maxWords) words in each spelling.")
        case .invalid(.tooLong):
            return String(localized: "Use at most \(DictionaryValidation.maxScalars) characters in each spelling.")
        case .invalid(.noLetter): return String(localized: "Include a letter in each spelling.")
        case .invalid(.unencodable):
            return String(localized: "A spelling contains characters the speech model can’t produce.")
        // Spellings have no strength of their own.
        case .invalid(.invalidStrength): return DictionaryEntryError.invalidStrength.message
        case .comma: return String(localized: "A spelling can’t contain a comma.")
        case .sameAsWord: return String(localized: "A spelling can’t be the word itself.")
        case .tooMany: return String(localized: "Use at most \(SoundsLike.maxSpellings) spellings.")
        case .taken: return String(localized: "A spelling is already another word or one of its spellings.")
        }
    }
}

/// An entry's sounds-like spellings: the wrong forms the recognizer writes for it (DESIGN §3.7). They are boosted with
/// the entry, and a spelling written in a transcript is replaced by the entry.
public enum SoundsLike {
    /// The most spellings an entry has.
    public static let maxSpellings = 4

    /// The spellings typed into Settings' "Sounds like" field: split at commas, trimmed, empty pieces dropped. Each is
    /// normalized when it is validated.
    public static func parse(_ field: String) -> [String] {
        field.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !DictionaryText.words($0.unicodeScalars).isEmpty }
    }

    /// The spellings `spellings` makes for the entry `word`, normalized and in order, a repeat by key kept once; or the
    /// first rule one breaks. Without a vocabulary the encodability check is skipped, as for entries. Whether another
    /// entry has a spelling's key is the dictionary's to check.
    public static func validate(_ spellings: [String], word: String,
                                encoder: BPEEncoder?) -> Result<[String], SoundsLikeError> {
        let wordKey = DictionaryKey(DictionaryValidation.normalize(word))
        var result: [String] = []
        var keys: Set<DictionaryKey> = []
        for spelling in spellings {
            if spelling.unicodeScalars.contains(",") { return .failure(.comma) }
            switch DictionaryValidation.validate(text: spelling, strength: DictionaryValidation.defaultStrength,
                                                 encoder: encoder) {
            case .failure(let error):
                return .failure(.invalid(error))
            case .success(let validated):
                let key = validated.key
                if key == wordKey { return .failure(.sameAsWord) }
                if keys.insert(key).inserted { result.append(validated.text) }
            }
        }
        guard result.count <= maxSpellings else { return .failure(.tooMany) }
        return .success(result)
    }

    private struct Pattern {
        let spelling: [Unicode.Scalar]
        let folded: [Unicode.Scalar]
        let entry: [Unicode.Scalar]
    }

    /// `transcript` with every whole-word run whose fold is a spelling's replaced by that spelling's entry, longest
    /// spelling first, never rescanning a replacement.
    public static func replace(_ transcript: String, entries: [DictionaryEntry]) -> String {
        let patterns = entries.flatMap { entry in
            entry.soundsLike.map { spelling in
                let scalars = Array(spelling.unicodeScalars)
                return Pattern(spelling: scalars, folded: DictionaryText.fold(scalars),
                               entry: Array(entry.text.unicodeScalars))
            }
        }
        // Longest first, then by spelling in scalar order.
        .sorted { lhs, rhs in
            if lhs.spelling.count != rhs.spelling.count { return lhs.spelling.count > rhs.spelling.count }
            return lhs.spelling.lexicographicallyPrecedes(rhs.spelling) { $0.value < $1.value }
        }
        guard !patterns.isEmpty else { return transcript }

        let input = Array(transcript.unicodeScalars)
        let folds = input.map(DictionaryText.fold)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var position = 0
        scan: while position < input.count {
            if position == 0 || !DictionaryText.isWordCharacter(input[position - 1]) {
                for pattern in patterns {
                    if let end = DictionaryText.foldedRun(pattern.folded, folds: folds, from: position),
                       end == input.count || !DictionaryText.isWordCharacter(input[end]) {
                        output += pattern.entry
                        position = end
                        continue scan
                    }
                }
            }
            output.append(input[position])
            position += 1
        }
        return DictionaryText.string(output)
    }
}

/// What the dictionary does to a raw transcript before any text rule: spellings become their entries (DESIGN §3.7),
/// then casing is restored (§1.4). Every decode is written this way, so a verification re-decode reads as the
/// dictation did.
public enum TranscriptRestorer {
    public static func apply(_ transcript: String, entries: [DictionaryEntry]) -> String {
        CasingRestorer.apply(SoundsLike.replace(transcript, entries: entries), entries: entries)
    }
}

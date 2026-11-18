import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md.

/// The word the iPhone keyboard offers to add after the user fixed a dictation it inserted (DESIGN §4.1). The keyboard
/// has no dictionary, ignore list or vocabulary, so the offer is the Mac's first correction candidate without them; the
/// app verifies it against the dictation's audio before saving it.
public struct CorrectionOffer: Equatable, Sendable {
    /// The candidate's surface: the edited words, edge punctuation stripped, valid as an entry.
    public let word: String
    public let kind: CorrectionKind
    /// The typed words it replaces: half-open whitespace-split indices of `typed`.
    public let replacedWords: Range<Int>

    public init(word: String, kind: CorrectionKind, replacedWords: Range<Int>) {
        self.word = word
        self.kind = kind
        self.replacedWords = replacedWords
    }

    /// The first candidate of DESIGN §1.5 for `typed` (the dictation as inserted) and `edited` (the same text as the
    /// user left it), after the words the alignment inserts before `typed`'s first word or after its last are dropped:
    /// they were typed around the dictation, not in it. Nil when there is none.
    public static func find(typed: String, edited: String) -> CorrectionOffer? {
        let trimmed = droppingSurroundingWords(typed: typed, edited: edited)
        guard let candidate = CorrectionCandidates.find(before: typed, after: trimmed, dictionary: [], ignore: [],
                                                        encoder: nil).first else { return nil }
        return CorrectionOffer(word: candidate.surface, kind: candidate.kind, replacedWords: candidate.beforeRange)
    }

    /// How many words `text` holds as DictionaryKit splits it (DESIGN §1.5.2, before punctuation-only words are
    /// dropped), counted without keeping them: what an alignment of it would cost.
    public static func wordCount(_ text: String) -> Int {
        var count = 0, inWord = false
        for scalar in text.unicodeScalars {
            if DictionaryText.isWhitespace(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// `typed` with the words in `range` replaced by `word`: the edited text an app rebuilds from the text it inserted
    /// and an offer's range. Nil unless `range` lies within `typed`'s whitespace-split words and holds one to three of
    /// them that are not punctuation alone (DESIGN §1.5.2), as a candidate's typed side does.
    public static func replacing(_ range: Range<Int>, in typed: String, with word: String) -> String? {
        let words = DictionaryText.words(typed.unicodeScalars)
        guard range.lowerBound >= 0, range.upperBound <= words.count else { return nil }
        let counted = words[range].count { !DictionaryText.norm($0).isEmpty }
        guard (1...CorrectionCandidates.maxBlockWords).contains(counted) else { return nil }
        let pieces = words[..<range.lowerBound].map { DictionaryText.string($0) } + [word]
            + words[range.upperBound...].map { DictionaryText.string($0) }
        return pieces.joined(separator: " ")
    }

    /// `edited` without the words the alignment (§1.5.3) inserts before the first word of `typed` or after its last,
    /// with what lies between kept as it was split.
    static func droppingSurroundingWords(typed: String, edited: String) -> String {
        let old = DictionaryWord.split(typed), new = DictionaryWord.split(edited)
        guard !old.isEmpty, !new.isEmpty else { return edited }
        let operations = WordAlignment.align(old.map(\.norm), new.map(\.norm))
        var dropped = Set<Int>()
        for operation in operations {
            guard case .insert(let b, let beforeA) = operation else { continue }
            if beforeA == 0 || beforeA == old.count { dropped.insert(b) }
        }
        let kept = new.indices.filter { !dropped.contains($0) }
        guard let first = kept.first, let last = kept.last else { return "" }
        // From the first kept word to the last, every split word (punctuation-only ones too).
        let words = DictionaryText.words(edited.unicodeScalars)
        let range = new[first].index...new[last].index
        return words[range].map { DictionaryText.string($0) }.joined(separator: " ")
    }
}

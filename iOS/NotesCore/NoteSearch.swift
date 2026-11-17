import Foundation

/// A note as the unlocked vault shows it (ARCHITECTURE.md, "Notes", Reading).
struct Note: Equatable {
    var id: UUID
    /// The body with the pending runs merged in: what the note shows.
    var text: String
    /// The body alone.
    var body: String
    var created: Date
    /// The body's modified date, or a pending run's start if later.
    var modified: Date
    /// The runs not yet merged into the body, in order.
    var pendingRuns: [NotePendingRun]

    /// Whether a run of this note records now.
    var isRecording: Bool { pendingRuns.contains { $0.isRecording } }

    /// Newest first: by modified date, then created date, then ID, so the order is total.
    static func isNewer(_ lhs: Note, than rhs: Note) -> Bool {
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        if lhs.created != rhs.created { return lhs.created > rhs.created }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// A run not yet merged into its note's body.
struct NotePendingRun: Equatable {
    var id: UUID
    var place: NoteRunPlace
    /// Nil when the run's start record is missing or does not open.
    var startedAt: Date?
    /// The settled pieces written so far, in sequence.
    var pieces: [String]
    var isRecording: Bool
}

/// A note a search matched, with the ranges of its text that matched.
struct NoteSearchHit: Equatable {
    var note: Note
    /// Sorted, and joined where they overlap. Empty for a query with no terms.
    var matches: [Range<String.Index>]
}

/// Search over notes (ARCHITECTURE.md, "Notes", Library and search). Pure: a linear scan.
enum NoteSearch {
    /// The notes in which every term of `query` matches the start of a word, newest first.
    static func search(_ query: String, in notes: [Note]) -> [NoteSearchHit] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
        return notes.sorted(by: Note.isNewer).compactMap { note in
            matches(of: terms, in: note.text).map { NoteSearchHit(note: note, matches: $0) }
        }
    }

    /// The ranges of `text` the folded `terms` match at word starts, sorted and joined; nil if a term matches none.
    static func matches(of terms: [[Unicode.Scalar]], in text: String) -> [Range<String.Index>]? {
        let indices = Array(text.indices)
        let characters = indices.map { text[$0] }
        let folded = characters.map { fold(String($0)) }
        let starts = (0 ..< characters.count).filter { isWordStart($0, in: characters) }
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var matched = false
            for start in starts {
                guard let end = matchEnd(of: term, from: start, in: folded) else { continue }
                ranges.append(indices[start] ..< (end < indices.count ? indices[end] : text.endIndex))
                matched = true
            }
            guard matched else { return nil }
        }
        return joined(ranges)
    }

    /// The scalars of `text` folded for case, diacritics and width.
    static func fold(_ text: String) -> [Unicode.Scalar] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars)
    }

    /// The index of the character after the last one `term` reaches from `start`, or nil if it does not match there.
    /// A term may end inside a character's folding ("s" in "ß"); the match then covers the whole character.
    private static func matchEnd(of term: [Unicode.Scalar], from start: Int, in folded: [[Unicode.Scalar]]) -> Int? {
        var position = 0
        var index = start
        while position < term.count {
            guard index < folded.count else { return nil }
            for scalar in folded[index] where position < term.count {
                guard scalar == term[position] else { return nil }
                position += 1
            }
            index += 1
        }
        return index
    }

    /// A word starts at a character other than whitespace that follows whitespace or starts the text, and at a
    /// letter or digit that follows a character that is neither.
    private static func isWordStart(_ index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        guard !character.isWhitespace else { return false }
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous.isWhitespace { return true }
        return isLetterOrDigit(character) && !isLetterOrDigit(previous)
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func joined(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

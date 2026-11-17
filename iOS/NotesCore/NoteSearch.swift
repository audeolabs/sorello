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
    /// Whether every file of the run could be read. A run with one that could not shows what could be, and waits
    /// to be merged until all can.
    var isReadable: Bool
}

/// A note a search matched, with the ranges of its text that matched.
struct NoteSearchHit: Equatable {
    var note: Note
    /// The matched characters, as offsets into the note's text counted in characters: sorted, and joined where they
    /// overlap or touch. Empty for a query with no terms.
    var matchedCharacters: [Range<Int>]

    /// The matched ranges of `note.text`. Found by walking the text, so a list reads them for the rows it shows.
    var matches: [Range<String.Index>] {
        let text = note.text
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        var offset = 0
        func advance(to target: Int) -> String.Index {
            index = text.index(index, offsetBy: target - offset)
            offset = target
            return index
        }
        for range in matchedCharacters {
            let lower = advance(to: range.lowerBound)
            ranges.append(lower ..< advance(to: range.upperBound))
        }
        return ranges
    }
}

/// Search over notes (ARCHITECTURE.md, "Notes", Library and search). Pure: a linear scan.
enum NoteSearch {
    /// The notes in which every term of `query` matches the start of a word, newest first.
    static func search(_ query: String, in notes: [Note]) -> [NoteSearchHit] {
        Index(notes).search(query)
    }

    /// Notes made ready to be searched many times, as a search field does at every keystroke: each text is folded
    /// once, here, and a search only compares.
    struct Index {
        private struct Entry {
            var note: Note
            /// The text's characters folded, one after another.
            var folded: [Unicode.Scalar]
            /// Where each character's folding starts in `folded`, and the end of the last.
            var starts: [Int32]
            /// The characters a word starts at, ascending.
            var wordStarts: [Int32]
        }

        /// Newest first.
        private let entries: [Entry]

        init(_ notes: [Note]) {
            entries = notes.sorted(by: Note.isNewer).map { note in
                var folded: [Unicode.Scalar] = []
                var starts: [Int32] = []
                var wordStarts: [Int32] = []
                folded.reserveCapacity(note.text.utf8.count)
                var previous: Character?
                var count: Int32 = 0
                for character in note.text {
                    starts.append(Int32(folded.count))
                    if isWordStart(character, after: previous) { wordStarts.append(count) }
                    NoteSearch.appendFolding(of: character, to: &folded)
                    previous = character
                    count += 1
                }
                starts.append(Int32(folded.count))
                return Entry(note: note, folded: folded, starts: starts, wordStarts: wordStarts)
            }
        }

        /// The notes in which every term of `query` matches the start of a word, newest first.
        func search(_ query: String) -> [NoteSearchHit] {
            let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
            return entries.compactMap { entry in
                Self.matches(of: terms, in: entry).map { NoteSearchHit(note: entry.note, matchedCharacters: $0) }
            }
        }

        /// The characters the folded `terms` match at word starts, sorted and joined; nil if a term matches none.
        private static func matches(of terms: [[Unicode.Scalar]], in entry: Entry) -> [Range<Int>]? {
            var ranges: [Range<Int>] = []
            for term in terms {
                var matched = false
                for start in entry.wordStarts {
                    guard let end = matchEnd(of: term, from: Int(start), in: entry) else { continue }
                    ranges.append(Int(start) ..< end)
                    matched = true
                }
                guard matched else { return nil }
            }
            return joined(ranges)
        }

        /// The character after the last one `term` reaches from character `start`, or nil if it does not match
        /// there. A term may end inside a character's folding ("s" in "ß"); the match then covers the whole
        /// character.
        private static func matchEnd(of term: [Unicode.Scalar], from start: Int, in entry: Entry) -> Int? {
            let first = Int(entry.starts[start])
            let last = first + term.count
            guard last <= entry.folded.count else { return nil }
            for offset in 0 ..< term.count where entry.folded[first + offset] != term[offset] { return nil }
            var end = start + 1
            while Int(entry.starts[end]) < last { end += 1 }
            return end
        }

        private static func joined(_ ranges: [Range<Int>]) -> [Range<Int>] {
            var result: [Range<Int>] = []
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

    /// The scalars of `text` folded for case, diacritics and width.
    static func fold(_ text: String) -> [Unicode.Scalar] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars)
    }

    /// Appends `fold` of one character. A character that is one ASCII scalar folds to itself, or to its lowercase
    /// letter, which most of any text is, so it skips the general folding.
    private static func appendFolding(of character: Character, to folded: inout [Unicode.Scalar]) {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first, scalar.isASCII {
            let isUppercase = scalar.value >= 0x41 && scalar.value <= 0x5A
            folded.append(isUppercase ? Unicode.Scalar(UInt8(scalar.value + 0x20)) : scalar)
        } else {
            folded += fold(String(character))
        }
    }

    /// A word starts at a character other than whitespace that follows whitespace or starts the text, and at a
    /// letter or digit that follows a character that is neither.
    private static func isWordStart(_ character: Character, after previous: Character?) -> Bool {
        guard !character.isWhitespace else { return false }
        guard let previous else { return true }
        if previous.isWhitespace { return true }
        return isLetterOrDigit(character) && !isLetterOrDigit(previous)
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

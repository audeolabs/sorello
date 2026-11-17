import Foundation

/// Where a run goes in its note (ARCHITECTURE.md, "Notes", Place): at the end, or at a UTF-16 offset into the
/// note's text as it was shown when the run began.
enum NoteRunPlace: Equatable {
    case end
    case offset(Int)
}

/// Turns a run's pieces, with the note's text before and after the run's place, into the text that goes in. The
/// app's is the shared text rules; NotesCore holds none (ARCHITECTURE.md, "Notes", Formatting).
typealias NoteRunFormatter = (_ pieces: [String], _ before: Substring, _ after: Substring) -> String

/// A run as merging sees it: where it goes and what it holds.
struct NoteRunContent: Equatable {
    var place: NoteRunPlace
    var pieces: [String]
}

/// Merging runs into a note's text (ARCHITECTURE.md, "Notes", Reading and Merging). Pure.
enum NoteMerge {
    /// `body` with `runs` merged in, in order: each at its place in the text the runs before it made.
    static func merge(_ runs: [NoteRunContent], into body: String, format: NoteRunFormatter) -> String {
        runs.reduce(body) { text, run in
            let index = self.index(of: run.place, in: text)
            let inserted = format(run.pieces, text[..<index], text[index...])
            return String(text[..<index]) + inserted + String(text[index...])
        }
    }

    /// The index `place` names in `text`: the end, or the UTF-16 offset clamped to the text and moved back to a
    /// character boundary.
    static func index(of place: NoteRunPlace, in text: String) -> String.Index {
        guard case .offset(let offset) = place else { return text.endIndex }
        let utf16 = text.utf16
        guard offset > 0 else { return text.startIndex }
        guard offset < utf16.count else { return text.endIndex }
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        while index.samePosition(in: text) == nil {
            index = utf16.index(before: index)
        }
        return index
    }
}

import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// Restores the exact spelling of dictionary entries that carry case (DESIGN §1.4): the recognizer may hear "nixos"
/// and the entry says "NixOS". Runs on the raw transcript, before any text rule.
public enum CasingRestorer {
    private struct Pattern {
        let text: [Unicode.Scalar]
        let folded: [Unicode.Scalar]
    }

    /// `transcript` with every whole-word match of an entry that has a cased scalar replaced by the entry's text.
    public static func apply(_ transcript: String, entries: [DictionaryEntry]) -> String {
        let patterns = patterns(entries)
        guard !patterns.isEmpty else { return transcript }
        return DictionaryText.string(restore(Array(transcript.unicodeScalars), patterns: patterns).output)
    }

    /// Casing for the front of a transcript that is still growing (ARCHITECTURE.md, section 5, "Progress").
    /// `words` are its first words, which will not change, each free of white space; more may follow, one space
    /// apart. Returns how many leading words have casing that no word after them can change, and their text:
    /// `apply` over the whole transcript gives that text, then a space and `apply` over the remaining words.
    public static func settle(_ words: [String], entries: [DictionaryEntry]) -> (count: Int, text: String) {
        let patterns = patterns(entries)
        guard !patterns.isEmpty else { return (words.count, words.joined(separator: " ")) }
        // A match takes one space of the transcript for each space in its entry, since nothing else folds to a
        // space, so it ends at most `reach` words after the word it starts in. Every choice made before word
        // `words.count - reach` therefore sees only known words, as it would in the whole transcript: those are the
        // places the scan can be cut.
        let reach = patterns.map { $0.folded.count(where: { $0 == " " }) }.max() ?? 0
        let last = words.count - reach
        guard last > 0 else { return (0, "") }
        var input: [Unicode.Scalar] = [], cuts: [Int] = []
        for (index, word) in words.enumerated() {
            if index > 0 {
                input.append(" ")
                if index <= last { cuts.append(input.count) }
            }
            input += word.unicodeScalars
        }
        if last == words.count { cuts.append(input.count) }
        let (output, reached) = restore(input, patterns: patterns, cuts: cuts)
        guard let (cut, length) = reached else { return (0, "") }
        // Each cut but the end follows a space, which the output keeps as it is.
        let count = cut + 1
        let text = count == words.count ? output[...] : output[..<(length - 1)]
        return (count, DictionaryText.string(text))
    }

    /// Entries that can restore anything: those with a scalar that folding changes. Longest first, then by entry text
    /// in scalar order.
    private static func patterns(_ entries: [DictionaryEntry]) -> [Pattern] {
        entries.compactMap { entry -> Pattern? in
            let text = Array(entry.text.unicodeScalars)
            guard text.contains(where: { DictionaryText.fold($0) != [$0] }) else { return nil }
            return Pattern(text: text, folded: DictionaryText.fold(text))
        }
        .sorted { lhs, rhs in
            if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
            return lhs.text.lexicographicallyPrecedes(rhs.text) { $0.value < $1.value }
        }
    }

    /// The scan behind `apply`, left to right, never rescanning replaced text. `cuts` are ascending positions in
    /// `input`; `reached` is the last of them the scan stopped at rather than replaced across, by its index in
    /// `cuts`, with the output's length there.
    private static func restore(_ input: [Unicode.Scalar], patterns: [Pattern],
                                cuts: [Int] = []) -> (output: [Unicode.Scalar], reached: (Int, Int)?) {
        let folds = input.map(DictionaryText.fold)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var position = 0, nextCut = 0, reached: (Int, Int)?
        func stop() {
            while nextCut < cuts.count && cuts[nextCut] < position { nextCut += 1 }
            if nextCut < cuts.count && cuts[nextCut] == position {
                reached = (nextCut, output.count)
                nextCut += 1
            }
        }
        scan: while position < input.count {
            if !cuts.isEmpty { stop() }
            if position == 0 || !DictionaryText.isWordCharacter(input[position - 1]) {
                for pattern in patterns {
                    if let end = match(pattern.folded, folds: folds, from: position),
                       end == input.count || !DictionaryText.isWordCharacter(input[end]) {
                        output += pattern.text
                        position = end
                        continue scan
                    }
                }
            }
            output.append(input[position])
            position += 1
        }
        if !cuts.isEmpty { stop() }
        return (output, reached)
    }

    /// End of the shortest transcript run starting at `start` whose folded scalars equal `folded` exactly, or nil.
    private static func match(_ folded: [Unicode.Scalar], folds: [[Unicode.Scalar]], from start: Int) -> Int? {
        var offset = 0
        var index = start
        while offset < folded.count {
            guard index < folds.count else { return nil }
            let piece = folds[index]
            guard offset + piece.count <= folded.count,
                  folded[offset..<offset + piece.count].elementsEqual(piece) else { return nil }
            offset += piece.count
            index += 1
        }
        return index
    }
}

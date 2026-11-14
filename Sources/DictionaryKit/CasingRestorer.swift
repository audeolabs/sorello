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
        // Only entries with a scalar that folding changes can restore anything.
        let patterns = entries.compactMap { entry -> Pattern? in
            let text = Array(entry.text.unicodeScalars)
            guard text.contains(where: { DictionaryText.fold($0) != [$0] }) else { return nil }
            return Pattern(text: text, folded: DictionaryText.fold(text))
        }
        // Longest first, then by entry text in scalar order.
        .sorted { lhs, rhs in
            if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
            return lhs.text.lexicographicallyPrecedes(rhs.text) { $0.value < $1.value }
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
                        output += pattern.text
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

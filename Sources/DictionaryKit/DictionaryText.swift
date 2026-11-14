import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// Text units shared by every dictionary algorithm (DESIGN §1.0). Characters are Unicode scalars, and strings are
/// compared by exact scalar sequence: Swift's `String ==` treats canonically equivalent text as equal, which the
/// tokenizer and the Linux implementation do not.
enum DictionaryText {
    static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// Each scalar through its full lowercase mapping.
    static func fold<S: Sequence>(_ scalars: S) -> [Unicode.Scalar] where S.Element == Unicode.Scalar {
        var result: [Unicode.Scalar] = []
        for scalar in scalars { result.append(contentsOf: fold(scalar)) }
        return result
    }

    static func fold(_ text: String) -> [Unicode.Scalar] { fold(text.unicodeScalars) }

    static func fold(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        // ASCII fast path; identical to the full mapping.
        if scalar.isASCII {
            let value = scalar.value
            return [(0x41...0x5A).contains(value) ? Unicode.Scalar(UInt8(value + 0x20)) : scalar]
        }
        return Array(scalar.properties.lowercaseMapping.unicodeScalars)
    }

    /// The first scalar through its full uppercase mapping; the rest unchanged.
    static func upper1<S: Collection>(_ scalars: S) -> [Unicode.Scalar] where S.Element == Unicode.Scalar {
        guard let first = scalars.first else { return [] }
        return Array(first.properties.uppercaseMapping.unicodeScalars) + scalars.dropFirst()
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Letters, marks, decimal digits and connector punctuation.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if isLetter(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    /// The Unicode `Uppercase` property (pin P5).
    static func isUppercase(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isUppercase }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .control }

    static let edgePunctuation: Set<Unicode.Scalar> = Set(".,;:!?\"'“”‘’()[]{}…—–«»".unicodeScalars)

    static func isEdgePunctuation(_ scalar: Unicode.Scalar) -> Bool { edgePunctuation.contains(scalar) }

    /// Words split on any `White_Space` scalar; empty pieces are dropped.
    static func words<S: Sequence>(_ scalars: S) -> [[Unicode.Scalar]] where S.Element == Unicode.Scalar {
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if isWhitespace(scalar) {
                if !current.isEmpty { words.append(current); current = [] }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func stripEdgePunctuation<C: BidirectionalCollection>(_ scalars: C) -> [Unicode.Scalar]
    where C.Element == Unicode.Scalar {
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, isEdgePunctuation(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isEdgePunctuation(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return Array(scalars[start..<end])
    }

    /// `fold(w)` with leading and trailing edge punctuation removed.
    static func norm<C: BidirectionalCollection>(_ word: C) -> [Unicode.Scalar] where C.Element == Unicode.Scalar {
        stripEdgePunctuation(fold(word))
    }

    /// End of the shortest transcript run starting at `start` whose folded scalars equal `folded` exactly, each
    /// transcript scalar's fold consumed whole, or nil (DESIGN §1.4, §3.7). `folds` holds each transcript scalar's fold.
    static func foldedRun(_ folded: [Unicode.Scalar], folds: [[Unicode.Scalar]], from start: Int) -> Int? {
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

/// The identity of a dictionary entry: its text folded to lower case, compared and hashed by Unicode scalars, so
/// "NixOS" and "nixos" are the same entry while canonically equivalent spellings are not (DESIGN §1.1). The ignore
/// list and per-app limits are keyed by it too.
public struct DictionaryKey: Hashable, Sendable {
    let scalars: [Unicode.Scalar]

    /// The key of an entry's text.
    public init(_ text: String) { scalars = DictionaryText.fold(text) }

    init(folded scalars: [Unicode.Scalar]) { self.scalars = scalars }

    /// The folded text, as the dictionary file stores it.
    public var text: String { DictionaryText.string(scalars) }

    static let maxScalars = 300
    static let maxWords = 8

    /// Pin P6, checked on load and before saving: non-empty, at most 300 scalars and 8 space-separated words, no
    /// control scalars, and already folded. Folding a valid 100-scalar surface can lengthen it, so the limit is not
    /// §1.1's.
    public var isValid: Bool {
        !scalars.isEmpty && scalars.count <= Self.maxScalars
            && scalars.split(separator: " ", omittingEmptySubsequences: false).count <= Self.maxWords
            && !scalars.contains(where: DictionaryText.isControl)
            && DictionaryText.fold(scalars) == scalars
    }
}

import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// A word or phrase the recognizer is biased towards, and how strongly (DESIGN §1.1). Entries are made by
/// validation, so `text` is always stored normalized.
public struct DictionaryEntry: Equatable, Sendable {
    public var text: String
    /// A multiplier between 0.25 and 8; 1 is the default.
    public var strength: Float

    public init(text: String, strength: Float) {
        self.text = text
        self.strength = strength
    }

    /// The entry's identity: two entries with the same key are the same entry.
    public var key: DictionaryKey { DictionaryKey(text) }

    // Scalar equality: canonically equivalent spellings are different entries.
    public static func == (lhs: DictionaryEntry, rhs: DictionaryEntry) -> Bool {
        DictionaryText.same(lhs.text, rhs.text) && lhs.strength.bitPattern == rhs.strength.bitPattern
    }
}

/// Why a word cannot be an entry. The first rule that fails wins, in the order DESIGN §1.1 lists them.
public enum DictionaryEntryError: String, Error, Equatable, Sendable {
    // Raw values are the shared vector names (DESIGN §1.7).
    case empty
    case tooManyWords = "too-many-words"
    case tooLong = "too-long"
    case noLetter = "no-letter"
    case unencodable
    case invalidStrength = "bad-strength"

    /// A message for the person editing the dictionary. It never quotes what they typed.
    public var message: String {
        switch self {
        case .empty: return String(localized: "Enter a word or phrase.")
        case .tooManyWords: return String(localized: "Use at most \(DictionaryValidation.maxWords) words.")
        case .tooLong: return String(localized: "Use at most \(DictionaryValidation.maxScalars) characters.")
        case .noLetter: return String(localized: "Include at least one letter.")
        case .unencodable: return String(localized: "This text contains characters the speech model can’t produce.")
        case .invalidStrength: return String(localized: "Choose a strength between ×0.25 and ×8.")
        }
    }
}

/// The limits on entries and the one validation every entry passes (DESIGN §1.1).
public enum DictionaryValidation {
    public static let maxWords = 8
    public static let maxScalars = 100
    public static let minStrength: Float = 0.25
    public static let maxStrength: Float = 8
    public static let defaultStrength: Float = 1
    /// Entries in the whole dictionary, whatever their apps.
    public static let capacity = 1000
    public static let ignoreCapacity = 1000
    /// The strengths offered in Settings.
    public static let presets: [Float] = [0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8]

    /// Trims whitespace and collapses internal runs to one ASCII space.
    public static func normalize(_ text: String) -> String {
        DictionaryText.words(text.unicodeScalars).map { DictionaryText.string($0) }.joined(separator: " ")
    }

    public static func isValidStrength(_ strength: Float) -> Bool {
        strength.isFinite && strength >= minStrength && strength <= maxStrength
    }

    /// The entry `text` makes at `strength`, or the first rule it breaks. Without a vocabulary (no model) the
    /// encodability check is skipped; building the bias graph skips any unencodable surface anyway.
    public static func validate(text: String, strength: Float,
                                encoder: BPEEncoder?) -> Result<DictionaryEntry, DictionaryEntryError> {
        let words = DictionaryText.words(text.unicodeScalars)
        guard !words.isEmpty else { return .failure(.empty) }
        guard words.count <= maxWords else { return .failure(.tooManyWords) }
        let normalized = words.map { DictionaryText.string($0) }.joined(separator: " ")
        guard normalized.unicodeScalars.count <= maxScalars else { return .failure(.tooLong) }
        guard normalized.unicodeScalars.contains(where: DictionaryText.isLetter) else { return .failure(.noLetter) }
        // A control scalar is never a vocabulary piece, so it is unencodable even when no vocabulary is loaded (and
        // could never form a valid key, pin P6).
        if normalized.unicodeScalars.contains(where: DictionaryText.isControl) { return .failure(.unencodable) }
        if let encoder, !encoder.encodesWithoutUnknown(normalized) { return .failure(.unencodable) }
        guard isValidStrength(strength) else { return .failure(.invalidStrength) }
        return .success(DictionaryEntry(text: normalized, strength: strength))
    }

    /// A short label for a strength, such as "×1.41".
    public static func label(_ strength: Float) -> String {
        var text = String(format: "%.2f", Double(strength))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "×" + text
    }
}

enum DictionaryMutationError: Error, Equatable {
    case full
    /// The identity or ignore key fails pin P6; nothing is changed.
    case invalidKey
}

/// Entries and the ignore list, with the rules of DESIGN §1.1. Changes are made by the dictionary's editor, which
/// validates them first.
public struct CustomDictionary: Equatable, Sendable {
    /// In the order they were added.
    public private(set) var entries: [DictionaryEntry] = []
    /// Keys never offered as suggestions, in the order they were ignored.
    public private(set) var ignore: [DictionaryKey] = []

    public init() {}

    public func contains(_ key: DictionaryKey) -> Bool { entries.contains { $0.key == key } }

    public func isIgnored(_ key: DictionaryKey) -> Bool { ignore.contains(key) }

    /// Adds, or replaces the entry with the same identity key.
    mutating func upsert(_ entry: DictionaryEntry) -> DictionaryMutationError? {
        let key = entry.key
        guard key.isValid else { return .invalidKey }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = entry
            return nil
        }
        guard entries.count < DictionaryValidation.capacity else { return .full }
        entries.append(entry)
        return nil
    }

    @discardableResult
    mutating func remove(_ key: DictionaryKey) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func addIgnore(_ key: DictionaryKey) -> DictionaryMutationError? {
        guard key.isValid else { return .invalidKey }
        guard !ignore.contains(key) else { return nil }
        guard ignore.count < DictionaryValidation.ignoreCapacity else { return .full }
        ignore.append(key)
        return nil
    }

    @discardableResult
    mutating func removeIgnore(_ key: DictionaryKey) -> Bool {
        guard let index = ignore.firstIndex(of: key) else { return false }
        ignore.remove(at: index)
        return true
    }
}

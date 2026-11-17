import Foundation

// The dictionary screen's rules for what it shows: the strength presets and their labels, which validation message
// appears under the field and when, and the count against the limit (docs/dictionary/DESIGN.md, §1.1 and §3.3).
// Validation itself belongs to the dictionary; the app layer runs it and reports the result as a
// `DictionaryProblem`.

/// The strengths a word can be given, from 0.5 to 8, each about √2 above the one before.
nonisolated public enum StrengthPresets {
    /// The presets, weakest first.
    public static let values: [Double] = [0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8]
    /// A new word's strength.
    public static let defaultValue: Double = 1

    /// "×1.41": two decimals at most, trailing zeros dropped.
    public static func label(_ strength: Double) -> String {
        var text = String(format: "%.2f", strength)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "×" + text
    }

    /// For VoiceOver: "Strength 1.41".
    public static func spokenLabel(_ strength: Double) -> String {
        String(localized: "Strength \(String(label(strength).dropFirst()))")
    }

    /// The preset closest to `strength`, so a stored value that is not a preset (one saved from a correction
    /// suggestion, or a float rounded on its way through storage) still selects one.
    public static func nearest(to strength: Double) -> Double {
        values.min { abs($0 - strength) < abs($1 - strength) } ?? defaultValue
    }
}

/// Why a word cannot be added, as the dictionary reports it. Messages never quote the word.
nonisolated public enum DictionaryProblem: Equatable, Sendable {
    case empty
    case tooManyWords(limit: Int)
    case tooLong(limit: Int)
    case noLetter
    /// The model cannot spell it.
    case unencodable
    case full(capacity: Int)
    /// Words can be limited to at most this many apps in all.
    case appsFull(capacity: Int)
    /// Without the speech model's vocabulary nothing can be checked, so nothing can be edited.
    case needsModel
    /// The change could not be written to disk, so it was not made.
    case notSaved
    /// A spelling under "Sounds like" has too many words (DESIGN §3.7).
    case spellingTooManyWords(limit: Int)
    /// A spelling is too long.
    case spellingTooLong(limit: Int)
    /// A spelling has no letter.
    case spellingNoLetter
    /// The model cannot spell a spelling.
    case spellingUnencodable
    /// More spellings than a word can have.
    case tooManySpellings(limit: Int)
    /// A spelling is the word itself.
    case spellingIsTheWord
    /// A spelling is another word, or another word's spelling.
    case spellingTaken
    /// The word is another word's spelling.
    case wordIsASpelling

    /// One sentence that says what to do.
    public var message: String {
        switch self {
        case .empty: String(localized: "Enter a word or phrase.")
        case .tooManyWords(let limit): String(localized: "Use at most \(limit) words.")
        case .tooLong(let limit): String(localized: "Use at most \(limit) characters.")
        case .noLetter: String(localized: "Include at least one letter.")
        case .unencodable: String(localized: "This has characters the speech model can’t write.")
        case .full(let capacity): String(localized: "The dictionary is full (\(capacity.formatted()) words).")
        case .appsFull(let capacity): String(localized: "Words can be limited to at most \(capacity) apps.")
        case .needsModel: String(localized: "The dictionary can’t be changed until the speech model is available.")
        case .notSaved: String(localized: "The dictionary couldn’t be saved. Nothing was changed.")
        case .spellingTooManyWords(let limit): String(localized: "Use at most \(limit) words in each spelling.")
        case .spellingTooLong(let limit): String(localized: "Use at most \(limit) characters in each spelling.")
        case .spellingNoLetter: String(localized: "Include a letter in each spelling.")
        case .spellingUnencodable: String(localized: "A spelling has characters the speech model can’t write.")
        case .tooManySpellings(let limit): String(localized: "Use at most \(limit) spellings.")
        case .spellingIsTheWord: String(localized: "A spelling can’t be the word itself.")
        case .spellingTaken: String(localized: "A spelling is already another word or one of its spellings.")
        case .wordIsASpelling: String(localized: "This is already a spelling of another word.")
        }
    }

    /// Whether the problem is about what was typed, rather than about the dictionary as a whole.
    var isAboutDraft: Bool {
        switch self {
        case .empty, .tooManyWords, .tooLong, .noLetter, .unencodable, .spellingTooManyWords, .spellingTooLong,
             .spellingNoLetter, .spellingUnencodable, .tooManySpellings, .spellingIsTheWord, .spellingTaken,
             .wordIsASpelling: true
        case .full, .appsFull, .needsModel, .notSaved: false
        }
    }

    /// The message under the add field. A problem with what was typed shows once something is typed, so an empty
    /// field is never scolded; a problem with the dictionary as a whole always shows.
    public static func inlineMessage(draft: String, problem: DictionaryProblem?) -> String? {
        guard let problem else { return nil }
        if problem.isAboutDraft && draft.isEmpty { return nil }
        return problem.message
    }
}

/// "12 of 1,000 words".
nonisolated public enum DictionaryCount {
    /// The count of `count` against `capacity`, with numbers written for `locale`.
    public static func label(count: Int, capacity: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let count = count.formatted(.number.locale(locale))
        let capacity = capacity.formatted(.number.locale(locale))
        return String(localized: "\(count) of \(capacity) words")
    }
}

/// An app a word can be limited to. Only its bundle identifier and last known name are ever kept.
nonisolated public struct AppLimit: Identifiable, Hashable, Sendable {
    /// The bundle identifier.
    public var id: String
    /// The app's last known name.
    public var name: String

    /// An app.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One dictionary entry as the screen shows it.
nonisolated public struct DictionaryWord: Identifiable, Equatable, Sendable {
    /// The entry's identity key.
    public var id: String
    /// The word or phrase as stored.
    public var text: String
    /// Its strength, normally one of the presets.
    public var strength: Double
    /// Empty when the word applies everywhere.
    public var apps: [AppLimit]
    /// The spellings it is heard as, in order; usually none.
    public var soundsLike: [String]

    /// A word; with no apps, it applies everywhere.
    public init(id: String, text: String, strength: Double, apps: [AppLimit] = [], soundsLike: [String] = []) {
        self.id = id
        self.text = text
        self.strength = strength
        self.apps = apps
        self.soundsLike = soundsLike
    }

    /// The line under the word, "Sounds like Sarello, so rello", or nil when it has no spellings. Commas separate
    /// them, as they are typed.
    public var soundsLikeLabel: String? {
        guard !soundsLike.isEmpty else { return nil }
        return String(localized: "Sounds like \(soundsLikeField)")
    }

    /// The spellings as they are typed into "Sounds like".
    public var soundsLikeField: String { soundsLike.joined(separator: ", ") }
}

/// A word that is never suggested.
nonisolated public struct IgnoredWord: Identifiable, Equatable, Sendable {
    /// The ignored identity key.
    public var id: String
    /// The word as the suggestion offered it.
    public var text: String

    /// An ignored word.
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

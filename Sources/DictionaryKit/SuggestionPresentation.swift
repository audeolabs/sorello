import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// The buttons of a dictionary suggestion (DESIGN §3.5 and §3.6).
public enum DictionarySuggestionAction: Equatable, Sendable {
    /// Puts the word in the dictation's app when there is one, otherwise everywhere.
    case add
    /// Always makes the word apply everywhere.
    case addEverywhere
    case notNow
    /// Adds the word's key to the ignore list.
    case dontSuggest
}

/// The pill's only copy of a suggestion (DESIGN §3.5). Timers and button callbacks are bound to its id, so a stale
/// timer or a late click can never act on a later suggestion. Every way it leaves the screen (a button, the timeout,
/// pre-emption, the setting turned off) clears the word. Used on the main actor only.
public struct SuggestionPresentationGate: Sendable {
    /// How long a suggestion stays before it resolves as "Not now".
    public static let lifetime: TimeInterval = 12

    public private(set) var activeID: UUID?
    /// The suggestion on screen; nil once it is resolved or withdrawn.
    public private(set) var suggestion: DictionarySuggestion?

    /// Counts withdrawals (a recording press or start, a dictionary edit, the setting turned off). A presentation
    /// requested before one never shows.
    public private(set) var withdrawals: UInt64 = 0

    public init() {}

    /// Pre-empts the visible suggestion and voids every presentation already requested; one requested afterwards
    /// still shows.
    public mutating func withdraw() {
        withdrawals &+= 1
        preempt()
    }

    /// Presents `suggestion` if nothing was withdrawn since `requestedAt` (the `withdrawals` value when the
    /// presentation was requested).
    public mutating func present(_ suggestion: DictionarySuggestion, requestedAt: UInt64) -> UUID? {
        guard requestedAt == withdrawals else { return nil }
        return present(suggestion)
    }

    public mutating func present(_ suggestion: DictionarySuggestion) -> UUID {
        let id = UUID()
        activeID = id
        self.suggestion = suggestion
        return id
    }

    /// Another notice took the pill, or the suggestion was withdrawn.
    public mutating func preempt() {
        activeID = nil
        suggestion = nil
    }

    /// The suggestion, exactly once, if `id` is still the one on screen.
    public mutating func resolve(_ id: UUID) -> DictionarySuggestion? {
        guard activeID == id, let suggestion else { return nil }
        preempt()
        return suggestion
    }
}

/// When a verified suggestion may be shown (DESIGN §3.5): suggestions on, the dictionary editable, and no dictation
/// under way. A shortcut start that is pending or a shortcut held down already counts as under way.
public enum CorrectionSuggestionTiming {
    public static func mayPresent(enabled: Bool, dictionaryEditable: Bool, recording: Bool, transcribing: Bool,
                                  startPending: Bool, shortcutSessionActive: Bool) -> Bool {
        enabled && dictionaryEditable && !recording && !transcribing && !startPending && !shortcutSessionActive
    }
}

/// Whether a finished dictation may be watched for corrections (DESIGN §3.4). Decided on the main actor when its
/// insertion is reported.
public enum CorrectionEligibility {
    /// The longest inserted text that is watched, in UTF-8 bytes.
    public static let maxOutputBytes = 4096

    /// - `retained`: the speech result carries a correction id.
    /// - `snapshotRevision`: the dictionary revision the audio was decoded with; `currentRevision` the revision now.
    ///   An edit after recording started makes the retained audio obsolete.
    /// - `watchGeneration`: the watcher's generation when the dictation's text was composed; `currentGeneration`
    ///   differs once anything cancelled corrections.
    public static func isEligible(suggestionsEnabled: Bool, retained: Bool,
                                  snapshotRevision: UInt64, currentRevision: UInt64,
                                  watchGeneration: UInt64, currentGeneration: UInt64,
                                  usedMacro: Bool, pressesEnter: Bool, output: String) -> Bool {
        suggestionsEnabled && retained
            && snapshotRevision == currentRevision && watchGeneration == currentGeneration
            && !usedMacro && !pressesEnter && !output.isEmpty
            && output.utf8.count <= maxOutputBytes
    }
}

import Foundation

// The General screen's switches and the Macros screen's values.

/// A setting on the General screen that is on or off.
nonisolated public enum GeneralToggle: CaseIterable, Hashable, Sendable {
    case launchAtLogin
    case restoreClipboard
    case spokenNumbers
    case spokenDelimiters
    case pressEnter
    case correctionSuggestions
    case keepRunLog

    /// The switch's name.
    public var title: String {
        switch self {
        case .launchAtLogin: String(localized: "Open at login")
        case .restoreClipboard: String(localized: "Restore the clipboard")
        case .spokenNumbers: String(localized: "Numbers as digits")
        case .spokenDelimiters: String(localized: "Spoken quotes and brackets")
        case .pressEnter: String(localized: "Say “press enter” to send")
        case .correctionSuggestions: String(localized: "Suggest dictionary words")
        case .keepRunLog: String(localized: "Keep a Run Log")
        }
    }

    /// One line under the title.
    public var detail: String {
        switch self {
        case .launchAtLogin: String(localized: "Starts quietly in the menu bar.")
        case .restoreClipboard: String(localized: "Puts back what you had copied, a second after each paste.")
        case .spokenNumbers: String(localized: "“Twenty five” becomes 25.")
        case .spokenDelimiters: String(localized: "“Open quote” and “close bracket” become the marks.")
        case .pressEnter: String(localized: "Ending with “press enter” presses Return after the paste.")
        case .correctionSuggestions:
            String(localized: "When you fix a word right after dictating it, offers to add it.")
        case .keepRunLog: String(localized: "The last 20 dictations and their audio, kept only on this Mac.")
        }
    }

    /// The row's glyph.
    var symbol: String {
        switch self {
        case .launchAtLogin: "power"
        case .restoreClipboard: "doc.on.clipboard"
        case .spokenNumbers: "number"
        case .spokenDelimiters: "quote.opening"
        case .pressEnter: "return"
        case .correctionSuggestions: "text.badge.plus"
        case .keepRunLog: "clock.arrow.circlepath"
        }
    }
}

/// A microphone the user can choose.
nonisolated public struct MicrophoneOption: Identifiable, Hashable, Sendable {
    /// The device's unique identifier.
    public var id: String
    /// The device's name.
    public var name: String

    /// A microphone.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A voice macro: a complete spoken phrase replaced with saved text.
nonisolated public struct MacroItem: Identifiable, Equatable, Sendable {
    /// The macro's identifier, for the actions.
    public var id: String
    /// What is said.
    public var phrase: String
    /// What is pasted instead. May be empty, in which case nothing is pasted.
    public var text: String

    /// A macro.
    public init(id: String, phrase: String, text: String) {
        self.id = id
        self.phrase = phrase
        self.text = text
    }
}

/// Why a macro cannot be saved, as the text rules report it. Messages never quote the macro.
nonisolated public enum MacroProblem: Equatable, Sendable {
    case emptyPhrase
    /// Another macro is already said this way.
    case duplicatePhrase
    case phraseTooLong(limit: Int)
    case textTooLong(limit: Int)

    /// One sentence that says what to do.
    public var message: String {
        switch self {
        case .emptyPhrase: String(localized: "Enter what you’ll say.")
        case .duplicatePhrase: String(localized: "Another macro already uses this phrase.")
        case .phraseTooLong(let limit): String(localized: "Keep the phrase under \(limit) characters.")
        case .textTooLong(let limit): String(localized: "Keep the text under \(limit.formatted()) characters.")
        }
    }

    /// The message under the editor. A missing phrase is not pointed out until something has been typed in either
    /// field, so a new, empty editor is never scolded.
    public static func inlineMessage(phrase: String, text: String, problem: MacroProblem?) -> String? {
        guard let problem else { return nil }
        if problem == .emptyPhrase && phrase.isEmpty && text.isEmpty { return nil }
        return problem.message
    }
}

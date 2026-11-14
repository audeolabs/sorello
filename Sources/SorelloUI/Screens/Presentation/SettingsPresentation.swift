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
    /// Record from a built-in or wired microphone when the system default is a Bluetooth one.
    case avoidBluetoothMicrophone
    /// Whether the updater checks for a newer version once a day by itself. Only a build that can update itself has it.
    case checkForUpdates

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
        case .avoidBluetoothMicrophone: String(localized: "Avoid Bluetooth microphones")
        case .checkForUpdates: String(localized: "Check for updates automatically")
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
        case .avoidBluetoothMicrophone: "headphones"
        case .checkForUpdates: "arrow.down.circle"
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
    /// The macros file could not be written, or the macro was deleted meanwhile: nothing was saved.
    case notSaved

    /// One sentence that says what to do.
    public var message: String {
        switch self {
        case .emptyPhrase: String(localized: "Enter what you’ll say.")
        case .duplicatePhrase: String(localized: "Another macro already uses this phrase.")
        case .phraseTooLong(let limit): String(localized: "Keep the phrase under \(limit) characters.")
        case .textTooLong(let limit): String(localized: "Keep the text under \(limit.formatted()) characters.")
        case .notSaved: String(localized: "The macro couldn’t be saved. Try again.")
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

import Foundation

/// A spoken phrase that pastes saved text instead of itself. Saying exactly the command, and nothing else, inserts
/// `text` as it was saved: no spoken numbers, delimiters, fitting or prompt tag touch it.
public struct VoiceMacro: Identifiable, Codable, Hashable, Sendable {
    /// Stays the same when the macro is edited, so a list can follow it.
    public var id: UUID
    /// What the user says. Matched ignoring case, punctuation and the space around it (`matchKey`).
    public var command: String
    /// What is pasted. May be empty: the command then inserts nothing, which is a deliberate result.
    public var text: String

    public init(id: UUID = UUID(), command: String, text: String) {
        self.id = id
        self.command = command
        self.text = text
    }

    /// The form of `command` that a transcript is compared in. Two macros with the same key would be the same
    /// spoken command, and a macro whose key is empty could never be said.
    public var matchKey: String { Self.matchKey(for: command) }

    /// Lowercased, with punctuation removed and the ends trimmed, so "Blue bird." and "blue, bird" are the same
    /// phrase. Inner spacing is kept as written: the recognizer writes one space between words.
    public static func matchKey(for phrase: String) -> String {
        phrase.lowercased().components(separatedBy: .punctuationCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

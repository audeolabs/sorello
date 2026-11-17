import Foundation
import TextRules

/// The text a voice note's run puts in its note (ARCHITECTURE.md, "Voice notes", Formatting): the shared text rules
/// applied to the run as a whole, as a dictation's, and fitted to the note's text around the run's place. The app
/// gives `formatter(settings:)` to `NoteVault`, so the text shown while a run records and the text merged into the
/// note are the one function's. Pure.
enum NoteRunText {
    /// `pieces` joined by single spaces, as the engine's settled pieces join into its transcript, with spoken
    /// numbers and spoken delimiters as asked, never "press enter", no macros and no prompt tag, then fitted to
    /// `before` and `after` as a dictation is fitted to the text around the cursor. Nothing for no words.
    static func format(_ pieces: [String], before: Substring, after: Substring, spokenNumbers: Bool,
                       spokenDelimiters: Bool) -> String {
        let options = TextRuleOptions(pressEnterCommand: false, spokenNumbers: spokenNumbers,
                                      spokenDelimiters: spokenDelimiters, promptTag: "")
        return DictationRules.process(pieces.joined(separator: " "), options: options, promptStyle: false,
                                      before: String(before), after: String(after)).text
    }

    /// The formatter with the user's settings as they are when it runs.
    static func formatter(settings: SorelloSettings) -> NoteRunFormatter {
        { pieces, before, after in
            format(pieces, before: before, after: after, spokenNumbers: settings.spokenNumbersEnabled,
                   spokenDelimiters: settings.spokenDelimitersEnabled)
        }
    }
}

import Foundation

/// The user's text rules, as they were when a dictation started (ARCHITECTURE.md, section 1, "Rules, not a
/// language model"). A value, so a dictation keeps the rules it started with while the user edits them.
public struct TextRuleOptions: Sendable, Equatable {
    /// Checked in order; the first whose command matches the whole dictation wins.
    public var macros: [VoiceMacro]
    /// A trailing "press enter" is removed from the text and presses Return after the paste.
    public var pressEnterCommand: Bool
    /// "twenty three" becomes "23" (`SpokenNumberFormatter`).
    public var spokenNumbers: Bool
    /// Spoken pairs such as "quote … end quote" become punctuation (`SpokenDelimiterFormatter`).
    public var spokenDelimiters: Bool
    /// Put before a prompt-style dictation so an AI agent reading it knows it was dictated. Trimmed; an empty tag
    /// adds nothing.
    public var promptTag: String

    public init(macros: [VoiceMacro] = [], pressEnterCommand: Bool, spokenNumbers: Bool, spokenDelimiters: Bool,
                promptTag: String) {
        self.macros = macros
        self.pressEnterCommand = pressEnterCommand
        self.spokenNumbers = spokenNumbers
        self.spokenDelimiters = spokenDelimiters
        self.promptTag = promptTag
    }
}

/// What the text rules made of one transcript.
public struct TextRuleResult: Sendable, Equatable {
    /// The recognizer's transcript, exactly as it was given: what the Run Log shows as heard.
    public var heard: String
    /// The transcript trimmed and without its trailing "press enter": the words the rules and macros worked from.
    public var spoken: String
    /// What to insert, fitted to the text around the cursor. Empty when the dictation was only "press enter", or a
    /// macro whose saved text is empty; both are deliberate results, not silence.
    public var text: String
    /// Press Return after the text. May be true with empty `text`.
    public var pressEnter: Bool
    /// `text` is a macro's saved text.
    public var usedMacro: Bool
    /// `text` starts with the prompt tag.
    public var addedPromptTag: Bool

    public init(heard: String, spoken: String, text: String, pressEnter: Bool, usedMacro: Bool,
                addedPromptTag: Bool) {
        self.heard = heard
        self.spoken = spoken
        self.text = text
        self.pressEnter = pressEnter
        self.usedMacro = usedMacro
        self.addedPromptTag = addedPromptTag
    }
}

/// Turns a transcript into the text to insert, with small deterministic rules and no language model. Dictated
/// instructions are always text: nothing here acts on what was said except a trailing "press enter" and a macro's
/// exact command.
public enum DictationRules {
    private static let trailingPressEnter = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    /// Applies the rules in this order:
    ///
    /// 1. The transcript is trimmed. With the command on, a trailing "press enter" (and the punctuation around it)
    ///    is removed and sets `pressEnter`. What is left is `spoken`.
    /// 2. If `spoken` is exactly a macro's command (`VoiceMacro.matchKey`), the macro's saved text, trimmed, is the
    ///    result. Saved text is the user's own words: it is not fitted to the cursor and never tagged.
    /// 3. Otherwise spoken numbers, then spoken delimiters, are applied; the result is fitted to `before` and
    ///    `after` (`InsertionContextFormatter`); and in prompt style the tag goes in front of the fitted words.
    ///    The tag is never inserted alone.
    ///
    /// `before` and `after` are the text either side of the cursor, nil when they could not be read.
    public static func process(_ transcript: String, options: TextRuleOptions, promptStyle: Bool,
                               before: String? = nil, after: String? = nil) -> TextRuleResult {
        var spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var pressEnter = false
        if options.pressEnterCommand,
           let match = trailingPressEnter.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)),
           let range = Range(match.range, in: spoken) {
            spoken.removeSubrange(range)
            spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            pressEnter = true
        }

        let key = VoiceMacro.matchKey(for: spoken)
        if !key.isEmpty, let macro = options.macros.first(where: { $0.matchKey == key }) {
            return TextRuleResult(heard: transcript, spoken: spoken,
                                  text: macro.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  pressEnter: pressEnter, usedMacro: true, addedPromptTag: false)
        }

        let numbered = options.spokenNumbers ? SpokenNumberFormatter.format(spoken) : spoken
        let dictated = options.spokenDelimiters ? SpokenDelimiterFormatter.format(numbered) : numbered
        let tag = promptStyle ? options.promptTag.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let text = InsertionContextFormatter.text(for: dictated, prefix: tag, before: before, after: after)
        return TextRuleResult(heard: transcript, spoken: spoken, text: text, pressEnter: pressEnter,
                              usedMacro: false, addedPromptTag: !tag.isEmpty && !text.isEmpty)
    }
}

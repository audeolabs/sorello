import Foundation
import Testing
import TextRules

/// Fitting a dictation to the text around the insertion point: spacing, the first word's capital and the final
/// punctuation. All text is invented.
@Suite struct InsertionContextTests {
    private func text(_ transcript: String, before: String? = nil, after: String? = nil) -> String {
        InsertionContextFormatter.text(for: transcript, before: before, after: after)
    }

    private func expectEqual(_ got: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got == expected, sourceLocation: sourceLocation)
    }

    @Test func unknownContextOnlyTrims() {
        expectEqual(text("  Synthetic words. \n\t"), "Synthetic words.")
        expectEqual(text("Synthetic words."), "Synthetic words.")
    }

    @Test func emptyTranscriptInsertsNothing() {
        for transcript in ["", "   ", "\n\t "] {
            expectEqual(text(transcript), "")
            expectEqual(text(transcript, before: "Prefix", after: " suffix"), "")
        }
    }

    /// The case that motivated this: a cursor placed before the period that
    /// ends an earlier dictation.
    @Test func insertingIntoTheMiddleOfASentence() {
        expectEqual(
            text("Which ends like this one.", before: "It ends like this one", after: ". "),
            " which ends like this one")
        expectEqual(text("Middle words.", before: "Start of it", after: " end of it."), " middle words")
    }

    @Test func noSpaceAtStartOrAfterWhitespace() {
        for before in [nil, "", "Prefix ", "Prefix\n", "Prefix\t", "Prefix\u{00A0}"] as [String?] {
            expectEqual(text("synthetic", before: before), "synthetic")
        }
    }

    @Test func spaceAfterWordsAndPunctuation() {
        for before in ["Prefix", "Prefix.", "Prefix,", "Prefix:", "Prefix)", "Prefix]", "Prefix}", "42", "-", "…",
                       "Prefix\u{201D}", "Prefix\u{2019}", "🎙️"] {
            expectEqual(text("synthetic", before: before), " synthetic")
        }
    }

    @Test func noSpaceAfterOpeningBracketOrQuote() {
        for before in ["(", "Prefix [", "Prefix {", "Prefix \u{201C}", "Prefix \u{2018}", "Prefix \u{00AB}"] {
            expectEqual(text("synthetic", before: before), "synthetic")
        }
    }

    @Test func straightQuotesOpenOrClose() {
        for before in ["\"", "Prefix \"", "Prefix '", "(\"", "Prefix\n\""] {
            expectEqual(text("synthetic", before: before), "synthetic")
        }
        for before in ["\"Prefix\"", "Prefix'", "Prefix.\""] {
            expectEqual(text("synthetic", before: before), " synthetic")
        }
    }

    @Test func noSpaceBeforeClosingPunctuation() {
        for transcript in [".", ", then", "; more", ": list", "! yes", "? no", ") end", "] end", "} end"] {
            expectEqual(text(transcript, before: "Prefix"), transcript)
        }
        expectEqual(text("- item", before: "Prefix"), " - item")
    }

    /// After a letter, digit, comma, semicolon or em dash the dictation
    /// continues a sentence. A capitalized name is lowercased too; that
    /// occasional mistake is accepted.
    @Test func lowercasesTheFirstWordMidSentence() {
        for before in ["Prefix", "Prefix ", "Prefix,", "Prefix, ", "Prefix;", "Prefix \u{00A0}", "Prefix 42", "Prefix\u{2014}"] {
            expectEqual(text("Which words", before: before).trimmingCharacters(in: .whitespaces), "which words")
        }
        expectEqual(text("A Synthetic Title", before: "Prefix "), "a Synthetic Title")
        expectEqual(text("Don't stop", before: "Prefix "), "don't stop")
        expectEqual(text("Don\u{2019}t stop", before: "Prefix "), "don\u{2019}t stop")
        expectEqual(text("Élan here", before: "Prefix "), "élan here")
    }

    @Test func keepsTheCapitalAtASentenceStart() {
        for before in [nil, "", "   ", "Done.", "Done. ", "Really?", "Wow! ", "Done.\" ", "Line\n", "Line\n  ",
                       "Note:", "List:\n- ", "(", "\"", "Prefix-", "(aside) ", "e.g."] as [String?] {
            expectEqual(text("Which words", before: before).trimmingCharacters(in: .whitespaces), "Which words")
        }
    }

    @Test func keepsWordsThatAreNotPlainCapitalized() {
        for transcript in ["I think so", "I'm here", "I\u{2019}ll go", "I'd say", "I've seen", "NASA said", "SwiftUI runs",
                           "iPhone works", "\"Quoted\" words", "42 Words", "OK then"] {
            expectEqual(text(transcript, before: "Prefix "), transcript)
        }
    }

    /// Before following punctuation, the dictation's own closing punctuation
    /// would double it up.
    @Test func dropsPunctuationBeforePunctuation() {
        for after in [".", ". Next", ",", ", more", ";", ":", "!", "?", "\u{2026}"] {
            expectEqual(text("Ends here.", after: after), "Ends here")
        }
        expectEqual(text("Really?", after: "."), "Really")
        expectEqual(text("Wait...", after: "."), "Wait")
        expectEqual(text("Ends here", after: "."), "Ends here")
    }

    /// Before a lowercase word or a number, a final period would split the
    /// sentence; a question or exclamation mark is kept.
    @Test func dropsThePeriodBeforeAContinuation() {
        for after in [" and more", "  and more", "\u{00A0}and more", " 42 more"] {
            expectEqual(text("Ends here.", after: after), "Ends here")
        }
        expectEqual(text("Really?", after: " and more"), "Really?")
        expectEqual(text("Wow!", after: " and more"), "Wow!")
        expectEqual(text("Wait...", after: " and more"), "Wait...")
    }

    @Test func keepsPunctuationBeforeANewSentenceOrLineEnd() {
        for after in [nil, "", " ", "\n", " \nNext", " Next", "  The next", " \"Quoted\"", ")", "\"", "\u{201D}", " - item"] as [String?] {
            expectEqual(text("Ends here.", after: after), "Ends here.")
        }
    }

    /// Inserted right against a word or an opening bracket, a space separates
    /// them; before a lowercase word the period goes, before a capital or a
    /// bracket it stays.
    @Test func spaceBeforeATouchingWord() {
        expectEqual(text("Ends here.", after: "and more"), "Ends here ")
        expectEqual(text("Ends here.", after: "42"), "Ends here ")
        expectEqual(text("Ends here.", after: "Next one"), "Ends here. ")
        expectEqual(text("No period", after: "Next"), "No period ")
        expectEqual(text("Middle", before: "Prefix", after: "suffix"), " middle ")
        expectEqual(text("Done.", after: "(More details.)"), "Done. ")
        expectEqual(text("See", before: "Prefix ", after: "\u{201C}quoted\u{201D}"), "see ")
    }

    @Test func punctuationOnlyTranscriptIsKept() {
        expectEqual(text(".", before: "Prefix", after: "."), ".")
        expectEqual(text("?", after: " and more"), "?")
    }
}

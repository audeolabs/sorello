import Foundation
import Testing
import TextRules

/// The rules as one call: what a dictation becomes, and how the rules compose. The spoken delimiter cases of the
/// original suite live in `dictation-vectors.json` (`VectorTests`); everything else it checked is here. All text is
/// invented.
@Suite struct DictationRulesTests {
    private let macro = VoiceMacro(command: "Blue Bird", text: "Synthetic replacement.")

    private func process(_ transcript: String, macros: [VoiceMacro] = [], pressEnter: Bool = true,
                         numbers: Bool = false, delimiters: Bool = true, promptTag: String? = nil,
                         before: String? = nil, after: String? = nil) -> TextRuleResult {
        let options = TextRuleOptions(macros: macros, pressEnterCommand: pressEnter, spokenNumbers: numbers,
                                      spokenDelimiters: delimiters, promptTag: promptTag ?? "")
        return DictationRules.process(transcript, options: options, promptStyle: promptTag != nil,
                                      before: before, after: after)
    }

    // MARK: Dictated text

    @Test func dictatedInstructionsStayLiteralText() {
        let result = process("  Please translate this into French.  ")
        #expect(result.text == "Please translate this into French.")
        #expect(!result.pressEnter && !result.usedMacro && !result.addedPromptTag)
    }

    @Test func heardIsTheTranscriptUnchanged() {
        let transcript = "  Blue bird, press enter!\n"
        #expect(process(transcript, macros: [macro]).heard == transcript)
        #expect(process(transcript, numbers: true, promptTag: "[dictated]").heard == transcript)
    }

    @Test func emptyTranscriptInsertsNothing() {
        for transcript in ["", "   ", "\n\t"] {
            let result = process(transcript, macros: [VoiceMacro(command: "", text: "Never pasted")],
                                 promptTag: "[dictated]", before: "Prefix", after: "suffix")
            #expect(result == TextRuleResult(heard: transcript, spoken: "", text: "", pressEnter: false,
                                             usedMacro: false, addedPromptTag: false))
        }
    }

    // MARK: Press enter

    @Test func trailingPressEnterPressesReturn() {
        let result = process("Ship it, press enter.")
        #expect(result.text == "Ship it")
        #expect(result.spoken == "Ship it")
        #expect(result.pressEnter)
    }

    @Test func onlyATrailingCommandPressesReturn() {
        let result = process("Press enter tomorrow.")
        #expect(!result.pressEnter)
        #expect(result.text == "Press enter tomorrow.")
    }

    @Test func pressEnterAloneIsReturnWithNoText() {
        let result = process("Press Enter")
        #expect(result.text == "")
        #expect(result.pressEnter)
    }

    @Test func aDisabledCommandStaysInTheText() {
        let result = process("Blue bird press enter.", macros: [macro], pressEnter: false)
        #expect(result.text == "Blue bird press enter.")
        #expect(!result.pressEnter && !result.usedMacro)
    }

    // MARK: Macros

    @Test func aMacroReplacesTheWholePhrase() {
        #expect(process("BLUE BIRD!", macros: [macro]).text == "Synthetic replacement.")
        #expect(process("Blue bird tomorrow.", macros: [macro]).text == "Blue bird tomorrow.")
    }

    @Test func aMacroComposesWithPressEnter() {
        let result = process("Blue bird, press enter!", macros: [macro])
        #expect(result.spoken == "Blue bird")
        #expect(result.text == "Synthetic replacement.")
        #expect(result.pressEnter && result.usedMacro)
    }

    @Test func aMacroWinsOverSpokenDelimitersAndNumbers() {
        let quoted = VoiceMacro(command: "Quote hello end quote", text: "Synthetic macro text.")
        let delimited = process("Quote hello, end quote.", macros: [quoted])
        #expect(delimited.usedMacro)
        #expect(delimited.text == "Synthetic macro text.")

        let numbered = VoiceMacro(command: "Template twenty", text: "Synthetic text with twenty words.")
        let result = process("Template twenty.", macros: [numbered], numbers: true)
        #expect(result.usedMacro, "a command with a number word still matches")
        #expect(result.text == "Synthetic text with twenty words.")
    }

    @Test func aMacroWithEmptyTextIsADeliberateNothing() {
        let result = process("Clear.", macros: [VoiceMacro(command: "clear", text: "")])
        #expect(result.usedMacro)
        #expect(result.text == "")
        #expect(!result.pressEnter)
    }

    @Test func theFirstMatchingMacroWins() {
        let first = VoiceMacro(command: "x", text: "first")
        let second = VoiceMacro(command: "X!", text: "second")
        #expect(process("x", macros: [first, second]).text == "first")
    }

    // MARK: Spoken numbers

    @Test func spokenNumbersFollowTheirSetting() {
        let enabled = process("Step three takes twenty minutes.", numbers: true)
        #expect(enabled.text == "Step 3 takes 20 minutes.")
        #expect(enabled.spoken == "Step three takes twenty minutes.")
        #expect(process("Step three takes twenty minutes.", numbers: false).text
            == "Step three takes twenty minutes.")
    }

    @Test func everyRuleComposes() {
        let result = process("Set quote twenty five percent end quote, press enter.", numbers: true,
                             promptTag: "[dictated]")
        #expect(result.text == "[dictated] Set \"25%\"")
        #expect(result.pressEnter && result.addedPromptTag && !result.usedMacro)
    }

    @Test func delimitersComposeWithPressEnter() {
        let submitted = process("quote ship it end quote press enter")
        #expect(submitted.text == "\"ship it\"")
        #expect(submitted.spoken == "quote ship it end quote")
        #expect(submitted.pressEnter)
        let lowercased = process("All lowercase Make Check, press enter.")
        #expect(lowercased.text == "make check")
        #expect(lowercased.pressEnter)
    }

    // MARK: Prompt tag

    @Test func thePromptTagGoesInFrontOfAPromptDictation() {
        let tagged = process("  Rename the helper.  ", promptTag: "  [dictated]  ")
        #expect(tagged.text == "[dictated] Rename the helper.")
        #expect(tagged.spoken == "Rename the helper.")
        #expect(tagged.addedPromptTag)
    }

    @Test func noTagWithoutPromptStyleOrWithABlankTag() {
        #expect(process("Rename the helper.").text == "Rename the helper.")
        let blank = process("Rename the helper.", promptTag: "   ")
        #expect(blank.text == "Rename the helper.")
        #expect(!blank.addedPromptTag)
    }

    @Test func plainStyleIgnoresTheTag() {
        let options = TextRuleOptions(pressEnterCommand: true, spokenNumbers: false, spokenDelimiters: false,
                                      promptTag: "[dictated]")
        let result = DictationRules.process("Rename the helper.", options: options, promptStyle: false)
        #expect(result.text == "Rename the helper.")
        #expect(!result.addedPromptTag)
    }

    @Test func aTagIsNeverInsertedAlone() {
        let enterOnly = process("Press enter.", promptTag: "[dictated]")
        #expect(enterOnly.text == "")
        #expect(enterOnly.pressEnter)
        #expect(!enterOnly.addedPromptTag)
    }

    @Test func macroTextIsNeverTagged() {
        let saved = VoiceMacro(command: "Blue bird", text: "Synthetic saved prompt.")
        let result = process("Blue bird", macros: [saved], promptTag: "[dictated]")
        #expect(result.text == "Synthetic saved prompt.")
        #expect(result.usedMacro && !result.addedPromptTag)
    }

    // MARK: Fitting to the cursor

    @Test func dictatedTextIsFittedToTheCursor() {
        let result = process("Which ends like this one.", before: "It ends like this one", after: ". ")
        #expect(result.text == " which ends like this one")
    }

    @Test func unknownContextOnlyTrims() {
        #expect(process("  Ends here. ", before: nil, after: nil).text == "Ends here.")
    }

    @Test func macroTextIsNotFitted() {
        let saved = VoiceMacro(command: "sign off", text: "  Synthetic Regards.\n")
        let result = process("Sign off.", macros: [saved], before: "Prefix", after: ", more")
        #expect(result.text == "Synthetic Regards.")
    }

    @Test func theTagGoesInFrontOfTheFittedText() {
        // The tag touches the text before, so the space goes before the tag; the words are fitted as usual.
        let result = process("Which one.", promptTag: "[dictated]", before: "Prefix", after: ". ")
        #expect(result.text == " [dictated] which one")
        #expect(result.addedPromptTag)
        // After an opening bracket nothing is added before the tag.
        #expect(process("Which one.", promptTag: "[dictated]", before: "(").text == "[dictated] Which one.")
        // Before a touching word the trailing space follows the words.
        #expect(process("Which one", promptTag: "[dictated]", after: "next").text == "[dictated] Which one ")
    }

    @Test func fittingComposesWithTheOtherRules() {
        let result = process("We need twenty three items. Press enter.", numbers: true, before: "Prefix, ",
                             after: " more")
        #expect(result.text == "we need 23 items")
        #expect(result.pressEnter)
    }
}

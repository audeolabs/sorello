import Foundation
import Testing
@testable import SorelloUI

/// The dictionary's presets, labels, inline messages and count (docs/dictionary/DESIGN.md, §1.1 and §3.3).
struct DictionaryPresentationTests {
    @Test func thePresetsRunFromHalfToEight() {
        #expect(StrengthPresets.values == [0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8])
        #expect(StrengthPresets.values.contains(StrengthPresets.defaultValue))
    }

    @Test func labelsDropTrailingZeros() {
        #expect(StrengthPresets.values.map(StrengthPresets.label)
                == ["×0.5", "×1", "×1.41", "×2", "×2.83", "×4", "×5.66", "×8"])
        #expect(StrengthPresets.label(0.25) == "×0.25")
    }

    @Test func aStoredFloatStillReadsAsItsPreset() {
        let stored = Double(Float(1.41))
        #expect(StrengthPresets.label(stored) == "×1.41")
        #expect(StrengthPresets.nearest(to: stored) == 1.41)
    }

    @Test func aValueBetweenPresetsSelectsTheNearest() {
        #expect(StrengthPresets.nearest(to: 0.25) == 0.5)
        #expect(StrengthPresets.nearest(to: 1.6) == 1.41)
        #expect(StrengthPresets.nearest(to: 3.5) == 4)
        #expect(StrengthPresets.nearest(to: 100) == 8)
    }

    @Test func anEmptyFieldIsNeverScolded() {
        #expect(DictionaryProblem.inlineMessage(draft: "", problem: .empty) == nil)
        #expect(DictionaryProblem.inlineMessage(draft: "", problem: .noLetter) == nil)
    }

    @Test func aProblemWithTheTypedTextShowsOnceSomethingIsTyped() {
        #expect(DictionaryProblem.inlineMessage(draft: "  ", problem: .empty) == DictionaryProblem.empty.message)
        #expect(DictionaryProblem.inlineMessage(draft: "1234", problem: .noLetter)
                == DictionaryProblem.noLetter.message)
        #expect(DictionaryProblem.inlineMessage(draft: "Quorvex", problem: nil) == nil)
    }

    @Test func aProblemWithTheWholeDictionaryAlwaysShows() {
        #expect(DictionaryProblem.inlineMessage(draft: "", problem: .full(capacity: 1000))
                == DictionaryProblem.full(capacity: 1000).message)
        #expect(DictionaryProblem.inlineMessage(draft: "", problem: .needsModel) == DictionaryProblem.needsModel.message)
    }

    @Test func messagesNeverQuoteTheWord() {
        let problems: [DictionaryProblem] = [.empty, .tooManyWords(limit: 8), .tooLong(limit: 100), .noLetter,
                                             .unencodable, .full(capacity: 1000), .appsFull(capacity: 32), .needsModel]
        #expect(Set(problems.map(\.message)).count == problems.count)
        #expect(DictionaryProblem.tooManyWords(limit: 8).message.contains("8"))
        #expect(DictionaryProblem.tooLong(limit: 100).message.contains("100"))
    }

    @Test func theCountIsAgainstTheLimit() {
        let locale = Locale(identifier: "en_US")
        #expect(DictionaryCount.label(count: 12, capacity: 1000, locale: locale) == "12 of 1,000 words")
        #expect(DictionaryCount.label(count: 1000, capacity: 1000, locale: locale) == "1,000 of 1,000 words")
    }

    @Test func anEmptyMacroEditorIsNeverScolded() {
        #expect(MacroProblem.inlineMessage(phrase: "", text: "", problem: .emptyPhrase) == nil)
        #expect(MacroProblem.inlineMessage(phrase: "", text: "Example text", problem: .emptyPhrase)
                == MacroProblem.emptyPhrase.message)
        #expect(MacroProblem.inlineMessage(phrase: "sample sign off", text: "", problem: .duplicatePhrase)
                == MacroProblem.duplicatePhrase.message)
    }
}

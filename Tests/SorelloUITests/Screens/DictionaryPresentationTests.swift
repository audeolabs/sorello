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
        #expect(DictionaryProblem.inlineMessage(draft: "", problem: .notSaved) == DictionaryProblem.notSaved.message)
    }

    @Test func messagesNeverQuoteTheWord() {
        let problems: [DictionaryProblem] = [.empty, .tooManyWords(limit: 8), .tooLong(limit: 100), .noLetter,
                                             .unencodable, .full(capacity: 1000), .appsFull(capacity: 32), .needsModel,
                                             .notSaved]
        #expect(Set(problems.map(\.message)).count == problems.count)
        #expect(DictionaryProblem.tooManyWords(limit: 8).message.contains("8"))
        #expect(DictionaryProblem.tooLong(limit: 100).message.contains("100"))
    }

    @Test func spellingMessagesNeverQuoteASpelling() {
        let problems: [DictionaryProblem] = [.spellingTooManyWords(limit: 8), .spellingTooLong(limit: 100),
                                             .spellingNoLetter, .spellingUnencodable, .tooManySpellings(limit: 4),
                                             .spellingIsTheWord, .spellingTaken, .wordIsASpelling]
        let all = problems + [.empty, .tooManyWords(limit: 8), .tooLong(limit: 100), .noLetter, .unencodable]
        #expect(Set(all.map(\.message)).count == all.count, "Each says something different")
        #expect(DictionaryProblem.tooManySpellings(limit: 4).message.contains("4"))
        #expect(DictionaryProblem.spellingTooManyWords(limit: 8).message.contains("8"))
        #expect(DictionaryProblem.spellingTooLong(limit: 100).message.contains("100"))
    }

    /// The add card checks the word first and its spellings after, and a blank "Sounds like" field is not checked.
    @MainActor @Test func theAddCardChecksTheWordBeforeItsSpellings() {
        let model = DictionaryModel(words: [], ignored: [], knownApps: [])
        var asked: [(String, String?, String)] = []
        model.actions = DictionaryActions(
            validate: { $0 == "1234" ? .noLetter : nil },
            validateSoundsLike: { word, id, field in
                asked.append((word, id, field))
                return field.contains("x") ? .spellingTaken : nil
            })
        model.draft = DictionaryDraft(text: "1234", soundsLike: "x")
        #expect(model.draftProblem == .noLetter)
        model.draft.text = "Sorello"
        #expect(model.draftProblem == .spellingTaken)
        #expect(asked.last.map { [$0.0, $0.1 ?? "nil", $0.2] } == ["Sorello", "nil", "x"], "A new word has no id")
        model.draft.soundsLike = "  "
        let count = asked.count
        #expect(model.draftProblem == nil)
        #expect(asked.count == count, "A blank field is not checked")
    }

    /// A word's spellings open for editing as they would be typed, and the editor's problem comes from the dictionary.
    @MainActor @Test func aWordsSpellingsAreEditedInPlace() {
        let word = DictionaryWord(id: "sorello", text: "Sorello", strength: 1, soundsLike: ["Sarello", "so rello"])
        #expect(word.soundsLikeLabel == "Sounds like Sarello, so rello")
        #expect(DictionaryWord(id: "plexa", text: "Plexa", strength: 1).soundsLikeLabel == nil)
        let model = DictionaryModel(words: [word], ignored: [], knownApps: [])
        model.actions = DictionaryActions(validateSoundsLike: { word, id, field in
            word == "Sorello" && id == "sorello" && field == "sorello" ? .spellingIsTheWord : nil
        })
        model.editSoundsLike(of: word)
        #expect(model.editingSoundsLike == SoundsLikeDraft(wordID: "sorello", text: "Sarello, so rello"))
        #expect(model.soundsLikeProblem == nil)
        model.editingSoundsLike?.text = "sorello"
        #expect(model.soundsLikeProblem == .spellingIsTheWord)
        model.editingSoundsLike?.refusal = .notSaved
        #expect(model.soundsLikeProblem == .notSaved, "A refused save shows until the text changes")
        model.editingSoundsLike?.text = "Sarello"
        #expect(model.editingSoundsLike?.refusal == nil)
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

    @Test func aSaveThatFailedIsSaidOnceSomethingIsTyped() {
        #expect(MacroProblem.inlineMessage(phrase: "sample sign off", text: "", problem: .notSaved)
                == MacroProblem.notSaved.message)
        let problems: [MacroProblem] = [.emptyPhrase, .duplicatePhrase, .phraseTooLong(limit: 80),
                                        .textTooLong(limit: 4000), .notSaved]
        #expect(Set(problems.map(\.message)).count == problems.count)
    }
}

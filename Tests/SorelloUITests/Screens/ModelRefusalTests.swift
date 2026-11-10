import Testing
@testable import SorelloUI

/// A refused add or save stays explained until the user changes what was refused, and no longer.
@MainActor
struct ModelRefusalTests {
    @Test func changingTheAppsClearsADictionaryRefusal() {
        let model = DictionaryModel(words: [], ignored: [], knownApps: [AppLimit(id: "com.example.notes", name: "Notes")],
                                    draft: DictionaryDraft(text: "Quorvex", apps: ["com.example.notes"]))
        model.refusal = .appsFull(capacity: 32)
        #expect(model.draftProblem == .appsFull(capacity: 32))
        model.draft.apps = []
        #expect(model.refusal == nil)
        #expect(model.draftProblem == nil)
    }

    @Test func changingTheStrengthOrTextClearsADictionaryRefusal() {
        let model = DictionaryModel(words: [], ignored: [], knownApps: [], draft: DictionaryDraft(text: "Quorvex"))
        model.refusal = .unencodable
        model.draft.strength = 2
        #expect(model.refusal == nil)
        model.refusal = .unencodable
        model.draft.text = "Quorvexa"
        #expect(model.refusal == nil)
    }

    @Test func leavingTheDraftAloneKeepsTheRefusal() {
        let model = DictionaryModel(words: [], ignored: [], knownApps: [], draft: DictionaryDraft(text: "Quorvex"))
        model.refusal = .unencodable
        model.draft = DictionaryDraft(text: "Quorvex")
        #expect(model.refusal == .unencodable)
    }

    @Test func editingAMacroClearsItsRefusal() {
        let model = MacrosModel(macros: [], editing: MacroDraft(phrase: "sample sign-off"))
        model.refusal = .duplicatePhrase
        model.editing?.phrase = "sample farewell"
        #expect(model.refusal == nil)
        model.refusal = .duplicatePhrase
        model.editing = nil
        #expect(model.refusal == nil)
    }
}

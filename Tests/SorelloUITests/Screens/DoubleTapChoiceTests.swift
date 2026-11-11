import Testing
@testable import SorelloUI

/// The Shortcuts screen's choice of what a double tap of Hold to Talk does.
@MainActor
struct DoubleTapChoiceTests {
    @Test(arguments: DoubleTapChoice.allCases)
    func choosingAValueShowsItAndCallsTheSetterWithIt(choice: DoubleTapChoice) {
        var chosen: [DoubleTapChoice] = []
        let model = ShortcutsModel(recorders: [:], doubleTap: choice == .handsFree ? .off : .handsFree,
                                   promptTag: "[dictated]", setDoubleTap: { chosen.append($0) })
        model.choose(choice)
        #expect(model.doubleTap == choice)
        #expect(chosen == [choice])
    }

    @Test func eachChoiceHasANameAndOneSentence() {
        let titles = DoubleTapChoice.allCases.map(\.title)
        #expect(Set(titles).count == DoubleTapChoice.allCases.count, "the names differ")
        for choice in DoubleTapChoice.allCases {
            #expect(!choice.title.isEmpty && !choice.explanation.isEmpty)
            #expect(!(choice.title + choice.explanation).contains("\u{2014}"), "no em-dash")
            #expect(choice.explanation.hasSuffix("."))
        }
    }

    @Test func onlyThePromptUsesTheTag() {
        for choice in DoubleTapChoice.allCases {
            let model = ShortcutsModel(recorders: [:], doubleTap: choice, promptTag: "[dictated]")
            #expect(model.usesTag == (choice == .prompt))
        }
    }
}

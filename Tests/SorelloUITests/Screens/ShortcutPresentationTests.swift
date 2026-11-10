import Testing
@testable import SorelloUI

/// Shortcuts read the way the Mac writes them, in key caps, in sentences and to VoiceOver.
struct ShortcutPresentationTests {
    @Test func modifiersFollowTheMacsOrderWhateverOrderTheyArriveIn() {
        let combo = KeyCombo(modifiers: [.command(.either), .shift(.either), .control(.either), .option(.either)],
                             key: KeyName(label: "D"))
        #expect(combo.caps.map(\.symbol) == ["⌃", "⌥", "⇧", "⌘", "D"])
        #expect(combo.inlineLabel == "⌃⌥⇧⌘D")
    }

    @Test func fnComesFirstAndLeftBeforeRight() {
        let combo = KeyCombo(modifiers: [.option(.right), .function, .option(.left)])
        #expect(combo.caps.map(\.symbol) == ["fn", "⌥", "⌥"])
        #expect(combo.caps.map(\.side) == [nil, "left", "right"])
    }

    @Test func aRepeatedModifierIsShownOnce() {
        let combo = KeyCombo(modifiers: [.option(.either), .option(.either)], key: KeyName(label: "Space"))
        #expect(combo.caps.count == 2)
    }

    @Test func theDefaultIsFn() {
        #expect(KeyCombo.function.inlineLabel == "fn")
        #expect(KeyCombo.function.spokenLabel == "Function")
    }

    @Test func aSidedModifierReadsWithItsSide() {
        let combo = KeyCombo(modifiers: [.option(.right)])
        #expect(combo.inlineLabel == "Right ⌥")
        #expect(combo.spokenLabel == "Right Option")
    }

    @Test func aKeyIsSpokenByItsOwnName() {
        let combo = KeyCombo(modifiers: [.control(.either)], key: KeyName(label: "→", spoken: "Right Arrow"))
        #expect(combo.spokenLabel == "Control Right Arrow")
        #expect(combo.inlineLabel == "⌃→")
    }

    @Test func onlyHoldToTalkMustKeepAShortcut() {
        #expect(!ShortcutKind.holdToTalk.canBeUnset)
        #expect(ShortcutKind.tapToToggle.canBeUnset)
        #expect(ShortcutKind.pasteAgain.canBeUnset)
    }

    @Test func aRefusedDuplicateNamesTheActionThatHasIt() {
        let message = ShortcutRefusal.alreadyUsed(by: .pasteAgain).message
        #expect(message.contains(ShortcutKind.pasteAgain.title))
    }

    @Test func everyRefusalSaysSomething() {
        let refusals: [ShortcutRefusal] = [.empty, .escape, .typingKey, .alreadyUsed(by: .holdToTalk)]
        #expect(Set(refusals.map(\.message)).count == refusals.count)
        #expect(refusals.allSatisfy { !$0.message.isEmpty })
    }

    @Test func theLiveTestNamesTheHoldShortcut() {
        #expect(SetupCopy.testInstruction(hold: .function) == "Hold fn and say something. Your words appear here.")
        #expect(SetupCopy.testInstruction(hold: KeyCombo(modifiers: [.option(.right)]))
                == "Hold Right ⌥ and say something. Your words appear here.")
    }
}

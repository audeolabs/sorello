import CoreGraphics
import DictationCore
import MacPlatform
import Testing

/// The events the real poster would send, built but never posted, and the choice of paste key.
@Suite struct KeyPostingTests {
    @Test func everyEventCarriesTheTagAndOnlyTheModifiersAskedFor() throws {
        let (down, up) = try #require(SystemKeyPoster.events(key: KeyCode.ansiV, modifiers: .command))
        for event in [down, up] {
            #expect(event.getIntegerValueField(.eventSourceUserData) == SyntheticEvents.tag)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyCode.ansiV))
            #expect(event.flags.contains(.maskCommand))
            #expect(!event.flags.contains(.maskShift))
            #expect(!event.flags.contains(.maskAlternate))
            #expect(!event.flags.contains(.maskControl))
        }
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)

        let (returnDown, _) = try #require(SystemKeyPoster.events(key: KeyCode.returnKey, modifiers: []))
        #expect(returnDown.getIntegerValueField(.eventSourceUserData) == SyntheticEvents.tag)
        #expect(!returnDown.flags.contains(.maskCommand))
    }

    @Test func pasteKeyIsTheKeyThatTypesVWithCommand() {
        // QWERTY, and "Dvorak - QWERTY ⌘", whose Command layer is QWERTY.
        #expect(PasteKey.find { $0 == KeyCode.ansiV ? "v" : "x" } == KeyCode.ansiV)
        // Dvorak types "v" on the key labelled period (47).
        #expect(PasteKey.find { $0 == 47 ? "v" : "q" } == 47)
        // A layout that types no "v" has no paste key of its own.
        #expect(PasteKey.find { _ in "м" } == nil)
        // When two keys type "v", the ANSI V key wins.
        #expect(PasteKey.find { $0 == 3 || $0 == KeyCode.ansiV ? "v" : nil } == KeyCode.ansiV)
    }

    @MainActor @Test func theCurrentLayoutGivesAKey() {
        #expect(PasteKey.current() < 128)
    }
}

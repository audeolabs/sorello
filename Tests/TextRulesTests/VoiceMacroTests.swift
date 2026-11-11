import Foundation
import Testing
import TextRules

/// A macro's identity, its stored form and the phrase it matches. All text is invented.
@Suite struct VoiceMacroTests {
    @Test func matchKeyIgnoresCasePunctuationAndTheEnds() {
        #expect(VoiceMacro.matchKey(for: "  Blue, Bird! ") == "blue bird")
        #expect(VoiceMacro.matchKey(for: "CAFÉ") == "café")
        #expect(VoiceMacro(command: "Sign-off.", text: "").matchKey == "signoff")
    }

    @Test func aCommandOfOnlyPunctuationHasNoKey() {
        #expect(VoiceMacro.matchKey(for: "?!") == "")
        #expect(VoiceMacro.matchKey(for: "   ") == "")
    }

    @Test func codableRoundTripKeepsEveryField() throws {
        let macro = VoiceMacro(command: "synthetic sign off", text: "Invented closing text\nwith two lines.")
        let decoded = try JSONDecoder().decode(VoiceMacro.self, from: JSONEncoder().encode(macro))
        #expect(decoded == macro)
    }

    @Test func eachNewMacroHasItsOwnID() {
        #expect(VoiceMacro(command: "a", text: "b").id != VoiceMacro(command: "a", text: "b").id)
    }
}

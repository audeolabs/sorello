import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 14, "Turning them on": General's switch and its line, and where the Screen Note shortcut
/// shows.
@MainActor
struct ScreenNotesPresentationTests {
    static func general(on: Bool, granted: Bool) -> GeneralModel {
        let general = GeneralModel(modelName: "m", status: .sampleReady, microphones: [], selectedMicrophoneID: nil,
                                   defaultMicrophoneName: nil, toggles: [.screenNotes: on])
        general.screenRecordingGranted = granted
        return general
    }

    @Test func theSwitchSaysWhatItDoes() {
        #expect(GeneralToggle.screenNotes.title == "Record screen notes")
        #expect(ShortcutKind.screenNote.title == "Screen Note")
        #expect(ShortcutKind.screenNote.canBeUnset)
        #expect(ShortcutKind.pasteScreenNote.title == "Paste Screen Note")
        #expect(ShortcutKind.pasteScreenNote.canBeUnset)
    }

    @Test func thePermissionLineShowsWhileOffOrNotGranted() {
        let line = "Requires Screen Recording permission"
        #expect(Self.general(on: false, granted: false).screenNotesDetail == line)
        #expect(Self.general(on: false, granted: true).screenNotesDetail == line)
        #expect(Self.general(on: true, granted: false).screenNotesDetail == line)
        #expect(Self.general(on: true, granted: true).screenNotesDetail == nil)
    }

    @Test func screenNotesAreOffUntilTheAppSaysOtherwise() {
        let general = GeneralModel(modelName: "m", status: .sampleReady, microphones: [], selectedMicrophoneID: nil,
                                   defaultMicrophoneName: nil, toggles: [:])
        #expect(!general.isOn(.screenNotes))
        #expect(!general.screenRecordingGranted)
    }

    @Test func theMenuListsScreenNoteOnlyWhileItHasKeys() {
        let keys = KeyCombo(modifiers: [.option(.either), .shift(.either)], key: KeyName(label: "S"))
        func titles(_ shortcuts: [ShortcutKind: KeyCombo]) -> [String] {
            StatusMenuRow.rows(appName: "Sorello", status: .sampleReady, shortcuts: shortcuts, hasLastDictation: false)
                .filter { if case .shortcut = $0.id { true } else { false } }.map(\.title)
        }
        #expect(titles([.holdToTalk: .function]) == ["Hold to Talk", "Tap to Toggle", "Paste Again"])
        #expect(titles([.holdToTalk: .function, .screenNote: keys])
            == ["Hold to Talk", "Tap to Toggle", "Paste Again", "Screen Note"])
        #expect(titles([.holdToTalk: .function, .screenNote: keys, .pasteScreenNote: keys])
            == ["Hold to Talk", "Tap to Toggle", "Paste Again", "Screen Note", "Paste Screen Note"])
    }
}

import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 14, "Turning them on": General has the Screen notes card only where the system can
/// record a note, which the app layer says.
@MainActor
struct ScreenNotesCardTests {
    @Test("General offers screen notes unless the app layer says the system cannot record them")
    func generalOffersScreenNotesUnlessTold() {
        #expect(GeneralModel.sample().offersScreenNotes)
        let general = GeneralModel(modelName: "m", status: .sampleReady, microphones: [], selectedMicrophoneID: nil,
                                   defaultMicrophoneName: nil, toggles: [:], offersScreenNotes: false)
        #expect(general.offersScreenNotes == false)
    }
}

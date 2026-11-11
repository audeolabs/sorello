import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 6, "Updates": General has a switch, "Check for updates automatically", only in a build
/// that can update itself.
@MainActor
struct UpdateSwitchTests {
    @Test func theSwitchSaysWhatItDoes() {
        #expect(GeneralToggle.checkForUpdates.title == "Check for updates automatically")
        #expect(GeneralToggle.checkForUpdates.detail == "Once a day. Nothing is installed until you choose Install.")
    }

    /// A General screen offers the switch only when the app layer says the build can update itself.
    @Test func generalOffersTheSwitchOnlyWhenTold() {
        #expect(GeneralModel.sample().offersUpdates == false)
        let general = GeneralModel(modelName: "m", status: .sampleReady, microphones: [], selectedMicrophoneID: nil,
                                   defaultMicrophoneName: nil, toggles: [.checkForUpdates: true], offersUpdates: true)
        #expect(general.offersUpdates)
        #expect(general.isOn(.checkForUpdates))
    }
}

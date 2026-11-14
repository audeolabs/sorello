import Testing
@testable import SorelloUI

/// ARCHITECTURE.md, section 6, "Audio capture", and section 8, "Windows": General's switch for Bluetooth headsets, and
/// the line under Microphone that names the microphone standing in for a Bluetooth default.
@MainActor
struct MicrophoneStandInTests {
    @Test func theSwitchSaysWhatItDoes() {
        #expect(GeneralToggle.avoidBluetoothMicrophone.title == "Avoid Bluetooth microphones")
    }

    @Test func theMicrophoneRowNamesAStandInAndOtherwiseSaysNothing() {
        let general = GeneralModel.sample()
        #expect(general.standInMicrophoneName == nil)
        #expect(general.microphoneDetail == nil)
        general.standInMicrophoneName = "MacBook Pro Microphone"
        #expect(general.microphoneDetail == "Recording from MacBook Pro Microphone")
    }

    @Test func theSampleHasTheSwitchOn() {
        #expect(GeneralModel.sample().isOn(.avoidBluetoothMicrophone))
    }
}

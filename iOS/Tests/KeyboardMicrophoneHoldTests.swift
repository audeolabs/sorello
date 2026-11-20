import Foundation

/// `KeyboardMicrophoneHold` (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture, Held microphone).
enum KeyboardMicrophoneHoldTests {
    static var tests: [TestCase] {
        [
            ("holdsWhenEverythingHolds", testHoldsWhenEverythingHolds),
            ("everyConditionIsNeeded", testEveryConditionIsNeeded),
            ("onlyBluetoothOutputsAreHeadphones", testOnlyBluetoothOutputsAreHeadphones),
        ]
    }

    private static let good = KeyboardMicrophoneHold.Conditions(
        visible: true, tapDictatesInKeyboard: true, useBuiltInMicrophone: true, bluetoothHeadphones: true,
        dictationRunning: false, heldCaptureReported: false)

    private static func testHoldsWhenEverythingHolds() {
        TestSupport.expect(KeyboardMicrophoneHold.shouldHold(good), "the keyboard does not hold the microphone")
    }

    private static func testEveryConditionIsNeeded() {
        let changes: [(String, (inout KeyboardMicrophoneHold.Conditions) -> Void)] = [
            ("hidden or hiding", { $0.visible = false }),
            ("a tap that goes to the host", { $0.tapDictatesInKeyboard = false }),
            ("\"Use iPhone microphone\" off", { $0.useBuiltInMicrophone = false }),
            ("no Bluetooth headphones", { $0.bluetoothHeadphones = false }),
            ("a dictation running", { $0.dictationRunning = true }),
            ("a held capture that reported since the keyboard appeared", { $0.heldCaptureReported = true }),
        ]
        for (name, change) in changes {
            var conditions = good
            change(&conditions)
            TestSupport.expect(!KeyboardMicrophoneHold.shouldHold(conditions), "the keyboard holds the microphone with \(name)")
        }
    }

    private static func testOnlyBluetoothOutputsAreHeadphones() {
        for output in [KeyboardMicrophoneHold.Output.bluetoothA2DP, .bluetoothLE, .bluetoothHFP] {
            TestSupport.expect(KeyboardMicrophoneHold.bluetoothHeadphones(in: [output]), "\(output) is not headphones")
            TestSupport.expect(KeyboardMicrophoneHold.bluetoothHeadphones(in: [.other, output]),
                               "\(output) beside another output is not headphones")
        }
        TestSupport.expect(!KeyboardMicrophoneHold.bluetoothHeadphones(in: []), "no output is headphones")
        TestSupport.expect(!KeyboardMicrophoneHold.bluetoothHeadphones(in: [.other]), "the speaker or a wire is headphones")
    }
}

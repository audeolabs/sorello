import Foundation

/// `KeyboardMicrophoneHold` (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Capture, Held microphone).
enum KeyboardMicrophoneHoldTests {
    static var tests: [TestCase] {
        [
            ("holdsWhenEverythingHolds", testHoldsWhenEverythingHolds),
            ("everyConditionIsNeeded", testEveryConditionIsNeeded),
            ("onlyBluetoothOutputsAreHeadphones", testOnlyBluetoothOutputsAreHeadphones),
            ("headphonesStayForTheGrace", testHeadphonesStayForTheGrace),
            ("otherAudioKeepsAHoldFromOpeningOnly", testOtherAudioKeepsAHoldFromOpeningOnly),
        ]
    }

    private static let good = KeyboardMicrophoneHold.Conditions(
        visible: true, tapDictatesInKeyboard: true, useBuiltInMicrophone: true, bluetoothHeadphones: true,
        dictationCapturing: false, heldCaptureReported: false, otherAudioPlaying: false, holding: false)

    private static func testHoldsWhenEverythingHolds() {
        TestSupport.expect(KeyboardMicrophoneHold.shouldHold(good), "the keyboard does not hold the microphone")
    }

    private static func testEveryConditionIsNeeded() {
        let changes: [(String, (inout KeyboardMicrophoneHold.Conditions) -> Void)] = [
            ("hidden or hiding", { $0.visible = false }),
            ("a tap that goes to the host", { $0.tapDictatesInKeyboard = false }),
            ("\"Use iPhone microphone\" off", { $0.useBuiltInMicrophone = false }),
            ("no Bluetooth headphones", { $0.bluetoothHeadphones = false }),
            ("a dictation's capture open", { $0.dictationCapturing = true }),
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

    /// Music or a podcast playing as the keyboard appears: holding would pause it or drop it to call quality just for
    /// typing, so no hold opens. A hold already open stays, since its own WebKit audio may count as another app's.
    private static func testOtherAudioKeepsAHoldFromOpeningOnly() {
        var playing = good
        playing.otherAudioPlaying = true
        TestSupport.expect(!KeyboardMicrophoneHold.shouldHold(playing), "a hold opens while another app plays audio")
        playing.holding = true
        TestSupport.expect(KeyboardMicrophoneHold.shouldHold(playing), "an open hold lets go when other audio plays")
        var held = good
        held.holding = true
        TestSupport.expect(KeyboardMicrophoneHold.shouldHold(held), "an open hold lets go")
        // Every other condition still ends an open hold.
        held.bluetoothHeadphones = false
        TestSupport.expect(!KeyboardMicrophoneHold.shouldHold(held), "an open hold stays without headphones")
    }

    /// Each switch to the iPhone's microphone sends the output through the receiver for about a tenth of a second; the
    /// hold must not let go for that.
    private static func testHeadphonesStayForTheGrace() {
        TestSupport.expectEqual(KeyboardMicrophoneHold.headphonesGrace, 1)
        var watch = KeyboardMicrophoneHold.HeadphonesWatch()
        TestSupport.expect(!watch.observe(false, at: 10), "headphones never seen are present")
        TestSupport.expect(watch.observe(true, at: 10), "headphones in the route are not present")
        TestSupport.expect(watch.observe(false, at: 10.1), "headphones gone for a tenth of a second are not present")
        TestSupport.expect(watch.observe(false, at: 10.99), "headphones gone for under the grace are not present")
        TestSupport.expect(!watch.observe(false, at: 11), "headphones gone for the grace are present")
        // Back in the route, the grace counts from their last sighting.
        TestSupport.expect(watch.observe(true, at: 20), "headphones back in the route are not present")
        TestSupport.expect(watch.observe(true, at: 25), "headphones in the route are not present")
        TestSupport.expect(watch.observe(false, at: 25.5), "headphones gone for half a second are not present")
        TestSupport.expect(!watch.observe(false, at: 26.2), "headphones gone past the grace are present")
        // The keyboard hiding forgets them.
        _ = watch.observe(true, at: 30)
        watch.reset()
        TestSupport.expect(!watch.observe(false, at: 30.1), "headphones seen before the keyboard hid are present")
    }
}

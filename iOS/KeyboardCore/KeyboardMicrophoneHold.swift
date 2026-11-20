#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// Whether the keyboard holds the microphone before a tap (ARCHITECTURE.md, "In-keyboard dictation (experiment)",
/// Capture, Held microphone): with Bluetooth headphones, iOS records from them first and the switch to the iPhone takes
/// most of a second, so the keyboard makes it while it is up and records from the tap. Pure; judged at every pass.
enum KeyboardMicrophoneHold {
    struct Conditions: Equatable, Sendable {
        /// The keyboard is visible and not hiding.
        var visible: Bool
        /// A tap would dictate in the keyboard (`KeyboardDictationRoute.decide`).
        var tapDictatesInKeyboard: Bool
        /// The shared `useBuiltInMicrophone`.
        var useBuiltInMicrophone: Bool
        /// Bluetooth headphones are in the current route (`bluetoothHeadphones(in:)`).
        var bluetoothHeadphones: Bool
        var dictationRunning: Bool
        /// A held capture reported something since the keyboard appeared.
        var heldCaptureReported: Bool
    }

    /// An output of the audio session's current route, mirrored from `AVAudioSession.Port`.
    enum Output: Equatable, Sendable {
        case bluetoothA2DP, bluetoothLE, bluetoothHFP, other
    }

    static func shouldHold(_ conditions: Conditions) -> Bool {
        conditions.visible && conditions.tapDictatesInKeyboard && conditions.useBuiltInMicrophone
            && conditions.bluetoothHeadphones && !conditions.dictationRunning && !conditions.heldCaptureReported
    }

    static func bluetoothHeadphones(in outputs: [Output]) -> Bool {
        outputs.contains { $0 != .other }
    }
}
#endif

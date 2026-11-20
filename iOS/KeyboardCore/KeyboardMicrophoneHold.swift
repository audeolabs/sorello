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
        /// A dictation's capture is open (it is starting or recording); one that transcribes does not count.
        var dictationCapturing: Bool
        /// A held capture reported something since the keyboard appeared.
        var heldCaptureReported: Bool
    }

    /// An output of the audio session's current route, mirrored from `AVAudioSession.Port`.
    enum Output: Equatable, Sendable {
        case bluetoothA2DP, bluetoothLE, bluetoothHFP, other
    }

    static func shouldHold(_ conditions: Conditions) -> Bool {
        conditions.visible && conditions.tapDictatesInKeyboard && conditions.useBuiltInMicrophone
            && conditions.bluetoothHeadphones && !conditions.dictationCapturing && !conditions.heldCaptureReported
    }

    static func bluetoothHeadphones(in outputs: [Output]) -> Bool {
        outputs.contains { $0 != .other }
    }

    /// How long headphones gone from the route still count: each switch to the iPhone's microphone sends the output
    /// through the iPhone's receiver for about a tenth of a second.
    static let headphonesGrace: TimeInterval = 1

    /// Bluetooth headphones as the hold sees them: present while in the route, and for `headphonesGrace` after.
    struct HeadphonesWatch: Equatable, Sendable {
        private var lastSeen: TimeInterval?

        /// Notes whether they are in the route at `now`, a monotonic clock, and says whether they count as present.
        mutating func observe(_ inRoute: Bool, at now: TimeInterval) -> Bool {
            if inRoute { lastSeen = now }
            return lastSeen.map { now - $0 < KeyboardMicrophoneHold.headphonesGrace } ?? false
        }

        /// The keyboard hid.
        mutating func reset() {
            lastSeen = nil
        }
    }
}
#endif

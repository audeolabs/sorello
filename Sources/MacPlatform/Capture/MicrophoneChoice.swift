import Foundation

/// Which microphone a dictation records from (ARCHITECTURE.md, section 6, "Audio capture", Bluetooth headsets). The
/// capture adapter calls it to open a device, and the app calls it for the General screen, so both say the same.
///
/// A microphone chosen by name and still present is used as chosen. Otherwise the system default is used, unless it
/// is a Bluetooth device and `avoidBluetooth` is on: then the built-in microphone stands in for it, or failing that
/// the first wired input in the list's order. A silenced device (a built-in microphone behind a closed lid) never
/// stands in. With nothing to stand in, the Bluetooth default is used.
public enum MicrophoneChoice {
    public struct Resolution: Sendable, Equatable {
        /// The microphone to record from.
        public var device: AudioInputDevice
        /// The Bluetooth default that `device` stands in for; nil when `device` is the chosen one or the default.
        public var replacing: AudioInputDevice?

        public init(device: AudioInputDevice, replacing: AudioInputDevice?) {
            self.device = device
            self.replacing = replacing
        }
    }

    /// The microphone to record from among `devices`, in the system's order, or nil when the chosen microphone is
    /// not there and no device is the default.
    public static func resolve(_ devices: [AudioInputDevice], chosenID: String?,
                               avoidBluetooth: Bool) -> Resolution? {
        if let chosenID, let chosen = devices.first(where: { $0.id == chosenID }) {
            return Resolution(device: chosen, replacing: nil)
        }
        guard let systemDefault = devices.first(where: \.isDefault) else { return nil }
        guard avoidBluetooth, systemDefault.transport == .bluetooth else {
            return Resolution(device: systemDefault, replacing: nil)
        }
        let usable = devices.filter { !$0.isSilenced }
        let standIn = usable.first { $0.transport == .builtIn } ?? usable.first { $0.transport == .wired }
        guard let standIn else { return Resolution(device: systemDefault, replacing: nil) }
        return Resolution(device: standIn, replacing: systemDefault)
    }
}

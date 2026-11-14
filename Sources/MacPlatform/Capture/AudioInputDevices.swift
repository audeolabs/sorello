import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import IOKit

/// One microphone, for the picker in Settings and for `MicrophoneChoice`.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// How a device is connected, as far as choosing a stand-in for a Bluetooth default goes (ARCHITECTURE.md,
    /// section 6, "Audio capture").
    public enum Transport: Sendable, Equatable {
        /// Part of the Mac.
        case builtIn
        /// USB, Thunderbolt, FireWire, PCI, HDMI or DisplayPort.
        case wired
        /// Bluetooth, classic or LE.
        case bluetooth
        /// Anything else: virtual, aggregate, AirPlay, Continuity, AVB or unknown. Never stands in.
        case other

        /// From a Core Audio transport type (`kAudioDeviceTransportType…`), which `AVCaptureDevice.transportType`
        /// also reports.
        public init(coreAudio code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
                self = .wired
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            default: self = .other
            }
        }
    }

    /// The device's unique identifier, which `CaptureRequest.deviceID` takes and which stays the same across
    /// launches and reconnections.
    public var id: String
    public var name: String
    /// Whether this is the system's default input now.
    public var isDefault: Bool
    public var transport: Transport
    /// The device is there but cannot hear: a laptop's built-in microphone while its lid is closed.
    public var isSilenced: Bool

    public init(id: String, name: String, isDefault: Bool, transport: Transport = .other, isSilenced: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.transport = transport
        self.isSilenced = isSilenced
    }
}

/// The microphones attached to the Mac, and when that list or the default input changes. Listing devices needs no
/// permission and never prompts.
public struct AudioInputDevices: Sendable {
    public init() {}

    /// The input devices now, in the system's order.
    public func current() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                         position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let lidClosed = Self.lidClosed()
        return discovery.devices.map { device in
            let transport = AudioInputDevice.Transport(coreAudio: UInt32(bitPattern: device.transportType))
            return AudioInputDevice(id: device.uniqueID, name: device.localizedName,
                                    isDefault: device.uniqueID == defaultID, transport: transport,
                                    isSilenced: lidClosed && transport == .builtIn)
        }
    }

    /// Whether a laptop's lid is closed. The Mac disconnects the built-in microphone then. False on a Mac without a
    /// lid, and whenever the power manager does not say.
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// The current list, then the list again each time a device is added or removed, the default input changes,
    /// or the displays change (closing a laptop's lid changes them, and silences its microphone); an unchanged
    /// list is not repeated. Listening stops when the consumer stops iterating.
    public func changes() -> AsyncStream<[AudioInputDevice]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [AudioInputDevice].self,
                                                             bufferingPolicy: .bufferingNewest(1))
        let listener = HardwareListener { [self] in self.current() } yield: { continuation.yield($0) }
        continuation.onTermination = { _ in listener.cancel() }
        listener.start()
        return stream
    }
}

/// Core Audio's notices that the device list or the default input changed. They arrive on a private queue that
/// also serializes the comparison with the last list sent.
private final class HardwareListener: Sendable {
    private let queue = DispatchQueue(label: "sorello.audio-devices")
    private let list: @Sendable () -> [AudioInputDevice]
    private let yield: @Sendable ([AudioInputDevice]) -> Void
    // Safe: `last`, `block` and `displays` are read and written only on `queue`.
    private nonisolated(unsafe) var last: [AudioInputDevice]?
    private nonisolated(unsafe) var block: AudioObjectPropertyListenerBlock?
    private nonisolated(unsafe) var displays: (any NSObjectProtocol)?

    private static let properties = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    init(list: @escaping @Sendable () -> [AudioInputDevice], yield: @escaping @Sendable ([AudioInputDevice]) -> Void) {
        self.list = list
        self.yield = yield
    }

    func start() {
        queue.async { [self] in
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            self.block = block
            for var address in Self.properties {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            displays = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.refresh() }
            }
            refresh()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard let block else { return }
            for var address in Self.properties {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            self.block = nil
            if let displays { NotificationCenter.default.removeObserver(displays) }
            displays = nil
        }
    }

    /// On `queue`.
    private func refresh() {
        let now = list()
        guard now != last else { return }
        last = now
        yield(now)
    }
}

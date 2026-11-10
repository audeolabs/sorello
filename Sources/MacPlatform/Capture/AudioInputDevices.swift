@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// One microphone, for the picker in Settings.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// The device's unique identifier, which `CaptureRequest.deviceID` takes and which stays the same across
    /// launches and reconnections.
    public var id: String
    public var name: String
    /// Whether this is the system's default input now.
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
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
        return discovery.devices.map { device in
            AudioInputDevice(id: device.uniqueID, name: device.localizedName, isDefault: device.uniqueID == defaultID)
        }
    }

    /// The current list, then the list again each time a device is added or removed or the default input
    /// changes; an unchanged list is not repeated. Listening stops when the consumer stops iterating.
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
    // Safe: `last` and `block` are read and written only on `queue`.
    private nonisolated(unsafe) var last: [AudioInputDevice]?
    private nonisolated(unsafe) var block: AudioObjectPropertyListenerBlock?

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

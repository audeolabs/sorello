import CoreAudio
@testable import MacPlatform
import Testing

/// ARCHITECTURE.md, section 6, "Audio capture", Bluetooth headsets: which microphone a dictation records from.
struct MicrophoneChoiceTests {
    typealias Transport = AudioInputDevice.Transport

    private static func device(_ id: String, _ transport: Transport, isDefault: Bool = false,
                               isSilenced: Bool = false) -> AudioInputDevice {
        AudioInputDevice(id: id, name: "\(id) name", isDefault: isDefault, transport: transport, isSilenced: isSilenced)
    }

    private static let headset = device("headset", .bluetooth, isDefault: true)
    private static let builtIn = device("built-in", .builtIn)
    private static let usb = device("usb", .wired)
    private static let dock = device("dock", .wired)

    private func resolve(_ devices: [AudioInputDevice], chosen: String? = nil, avoid: Bool = true)
        -> MicrophoneChoice.Resolution? {
        MicrophoneChoice.resolve(devices, chosenID: chosen, avoidBluetooth: avoid)
    }

    @Test func theBuiltInMicrophoneStandsInForABluetoothDefault() {
        let resolution = resolve([Self.usb, Self.headset, Self.builtIn])
        #expect(resolution == MicrophoneChoice.Resolution(device: Self.builtIn, replacing: Self.headset))
    }

    @Test func withoutABuiltInMicrophoneTheFirstWiredInputStandsIn() {
        let resolution = resolve([Self.headset, Self.usb, Self.dock])
        #expect(resolution == MicrophoneChoice.Resolution(device: Self.usb, replacing: Self.headset))
    }

    @Test func aBuiltInMicrophoneBehindAClosedLidDoesNotStandIn() {
        let closed = Self.device("built-in", .builtIn, isSilenced: true)
        #expect(resolve([closed, Self.headset, Self.dock])
                == MicrophoneChoice.Resolution(device: Self.dock, replacing: Self.headset))
        #expect(resolve([closed, Self.headset]) == MicrophoneChoice.Resolution(device: Self.headset, replacing: nil))
    }

    /// Other Bluetooth devices, virtual and aggregate devices, AirPlay, Continuity and unknown transports all map to
    /// `.other` or `.bluetooth`, and neither stands in.
    @Test func onlyBuiltInAndWiredInputsStandIn() {
        let others = [Self.device("other-headset", .bluetooth), Self.device("virtual", .other)]
        #expect(resolve([Self.headset] + others) == MicrophoneChoice.Resolution(device: Self.headset, replacing: nil))
    }

    @Test func withTheSwitchOffTheBluetoothDefaultIsUsed() {
        #expect(resolve([Self.headset, Self.builtIn], avoid: false)
                == MicrophoneChoice.Resolution(device: Self.headset, replacing: nil))
    }

    @Test func aMicrophoneChosenByNameIsUsedAsChosenEvenBluetooth() {
        let other = Self.device("other-headset", .bluetooth)
        #expect(resolve([Self.headset, Self.builtIn, other], chosen: "other-headset")
                == MicrophoneChoice.Resolution(device: other, replacing: nil))
        #expect(resolve([Self.headset, Self.builtIn], chosen: "headset")
                == MicrophoneChoice.Resolution(device: Self.headset, replacing: nil))
    }

    @Test func aChosenMicrophoneThatIsGoneGivesWayToTheDefaultWhichMayBeReplaced() {
        #expect(resolve([Self.headset, Self.builtIn], chosen: "unplugged")
                == MicrophoneChoice.Resolution(device: Self.builtIn, replacing: Self.headset))
    }

    @Test func aDefaultThatIsNotBluetoothIsUsed() {
        let builtInDefault = Self.device("built-in", .builtIn, isDefault: true)
        let other = Self.device("teams", .other, isDefault: true)
        #expect(resolve([builtInDefault, Self.usb]) == MicrophoneChoice.Resolution(device: builtInDefault, replacing: nil))
        #expect(resolve([other, Self.builtIn]) == MicrophoneChoice.Resolution(device: other, replacing: nil))
    }

    @Test func withNoDefaultAndNoChoiceThereIsNothingToResolve() {
        #expect(resolve([]) == nil)
        #expect(resolve([Self.builtIn, Self.usb]) == nil)
    }

    /// The opener opens what the choice names. If that device has gone since the list was read, the start fails; it
    /// never falls back to the default, which may be the Bluetooth headset.
    @Test func theOpenerOpensTheChoiceAndNeverFallsBackToTheDefault() {
        let resolution = resolve([Self.headset, Self.builtIn])
        #expect(MicrophoneChoice.device(for: resolution, find: { $0 }, systemDefault: { "headset" }) == "built-in")
        #expect(MicrophoneChoice.device(for: resolution, find: { _ in nil }, systemDefault: { "headset" }) == nil)
        #expect(MicrophoneChoice.device(for: nil, find: { $0 }, systemDefault: { "unlisted" }) == "unlisted")
    }

    /// How Core Audio's transport types sort: the ones that may stand in, Bluetooth, and everything else.
    @Test(arguments: [
        (kAudioDeviceTransportTypeBuiltIn, Transport.builtIn),
        (kAudioDeviceTransportTypeUSB, .wired),
        (kAudioDeviceTransportTypeThunderbolt, .wired),
        (kAudioDeviceTransportTypeFireWire, .wired),
        (kAudioDeviceTransportTypePCI, .wired),
        (kAudioDeviceTransportTypeHDMI, .wired),
        (kAudioDeviceTransportTypeDisplayPort, .wired),
        (kAudioDeviceTransportTypeBluetooth, .bluetooth),
        (kAudioDeviceTransportTypeBluetoothLE, .bluetooth),
        (kAudioDeviceTransportTypeVirtual, .other),
        (kAudioDeviceTransportTypeAggregate, .other),
        (kAudioDeviceTransportTypeAutoAggregate, .other),
        (kAudioDeviceTransportTypeAirPlay, .other),
        (kAudioDeviceTransportTypeAVB, .other),
        (kAudioDeviceTransportTypeContinuityCaptureWired, .other),
        (kAudioDeviceTransportTypeContinuityCaptureWireless, .other),
        (kAudioDeviceTransportTypeUnknown, .other),
    ])
    func coreAudioTransportsSort(code: UInt32, transport: Transport) {
        #expect(Transport(coreAudio: code) == transport)
    }
}

import DictationCore
import MacPlatform
import SorelloUI
import Synchronization
import Testing
@testable import SorelloApp

/// ARCHITECTURE.md, section 6, "Audio capture", Bluetooth headsets: General shows the microphone that stands in for a
/// Bluetooth default and has the switch, and a dictation carries the switch to the capture.
@MainActor
struct MicrophoneStandInTests {
    private static let headset = AudioInputDevice(id: "headset", name: "Sample Headphones", isDefault: true,
                                                  transport: .bluetooth)
    private static let builtIn = AudioInputDevice(id: "built-in", name: "Desk Microphone", isDefault: false,
                                                  transport: .builtIn)

    @Test func generalShowsTheStandInAndItsSwitch() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults,
                              microphones: FakeMicrophones(devices: [Self.headset, Self.builtIn]))
        harness.app.start()
        let general = harness.windows.main.general
        await eventually { general.standInMicrophoneName == "Desk Microphone" }
        #expect(general.isOn(.avoidBluetoothMicrophone))
        #expect(general.defaultMicrophoneName == "Sample Headphones")

        general.actions.setToggle(.avoidBluetoothMicrophone, false)
        #expect(!harness.app.settings.avoidBluetoothMicrophone)
        await eventually { general.standInMicrophoneName == nil && !general.isOn(.avoidBluetoothMicrophone) }

        general.actions.setToggle(.avoidBluetoothMicrophone, true)
        await eventually { general.standInMicrophoneName == "Desk Microphone" }

        // A microphone chosen by name is used as chosen, so nothing stands in.
        general.actions.selectMicrophone("headset")
        await eventually { general.standInMicrophoneName == nil }
    }

    /// General follows the device list: a headset that becomes the default, a lid that closes on the built-in
    /// microphone, and a headset that goes away.
    @Test func generalFollowsTheDevices() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let devices = ChangingMicrophones()
        let builtInDefault = AudioInputDevice(id: "built-in", name: "Desk Microphone", isDefault: true,
                                              transport: .builtIn)
        let dock = AudioInputDevice(id: "dock", name: "Dock Microphone", isDefault: false, transport: .wired)
        devices.send([builtInDefault, dock])
        let harness = Harness(directory: directory.url, defaults: suite.defaults, microphones: devices)
        harness.app.start()
        let general = harness.windows.main.general
        await eventually { general.defaultMicrophoneName == "Desk Microphone" }
        #expect(general.standInMicrophoneName == nil)

        devices.send([Self.headset, Self.builtIn, dock])
        await eventually { general.standInMicrophoneName == "Desk Microphone" }

        var closed = Self.builtIn
        closed.isSilenced = true
        devices.send([Self.headset, closed, dock])
        await eventually { general.standInMicrophoneName == "Dock Microphone" }

        devices.send([builtInDefault, dock])
        await eventually { general.standInMicrophoneName == nil && general.defaultMicrophoneName == "Desk Microphone" }
    }

    @Test func nothingStandsInForADefaultThatIsNotBluetooth() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        harness.app.start()
        await eventually { harness.windows.main.general.microphones.count == 1 }
        #expect(harness.windows.main.general.standInMicrophoneName == nil)
    }

    @Test func aDictationCarriesTheSwitch() async throws {
        let directory = try TemporaryDirectory(), suite = try TemporaryDefaults()
        let harness = Harness(directory: directory.url, defaults: suite.defaults)
        harness.app.start()
        await harness.dictate()
        harness.app.settings.avoidBluetoothMicrophone = false
        await eventually { harness.app.runtime.state.pipeline.isEmpty }
        await harness.dictate()
        await eventually { harness.capture.requests.count == 2 }
        #expect(harness.capture.requests.map(\.avoidBluetooth) == [true, false])
    }
}

/// A device list the test changes, as Core Audio's notices would.
private final class ChangingMicrophones: MicrophoneListing {
    private let (stream, continuation) = AsyncStream.makeStream(of: [AudioInputDevice].self)
    private let latest = Mutex<[AudioInputDevice]>([])

    func send(_ devices: [AudioInputDevice]) {
        latest.withLock { $0 = devices }
        continuation.yield(devices)
    }

    func current() -> [AudioInputDevice] { latest.withLock { $0 } }
    func changes() -> AsyncStream<[AudioInputDevice]> { stream }
}

import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Observation
import Persistence
import SorelloUI
import Synchronization
import Testing
@testable import SorelloApp

// Fakes for every adapter the composition is built from. None of them touches the keyboard, the pasteboard, the
// microphone, the screen or a permission.

/// A microphone whose audio the test hands over.
final class FakeCapture: AudioCapturing {
    final class Capture: AudioCapture {
        let events: AsyncStream<CaptureEvent>
        let continuation: AsyncStream<CaptureEvent>.Continuation

        init() { (events, continuation) = AsyncStream.makeStream() }

        func stop() async { continuation.finish() }
        func abort() { continuation.finish() }
    }

    private let current = Mutex<[Capture]>([])

    func start(_ request: CaptureRequest) async throws -> any AudioCapture {
        let capture = Capture()
        current.withLock { $0.append(capture) }
        return capture
    }

    var starts: Int { current.withLock { $0.count } }

    /// Delivers `seconds` of quiet speech-like audio to the newest capture.
    func deliver(seconds: Double, at time: TimeInterval) {
        let samples = (0..<Int(seconds * AudioFormat.sampleRate)).map { Float(sin(Double($0) * 0.05) * 0.2) }
        current.withLock { $0.last }?.continuation.yield(.chunk(AudioChunk(samples: samples, time: time)))
    }
}

/// Pastes nothing: composes for the destination the test chose and records what would have been pasted.
final class FakeInserter: AppInserting {
    private struct State {
        var destination: InsertionDestination = .cursor(context: nil, field: nil)
        var composed: [ComposedInsertion] = []
        var idleWaits = 0
        var neverIdle = false
        var stuck: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var destination: InsertionDestination {
        get { state.withLock { $0.destination } }
        set { state.withLock { $0.destination = newValue } }
    }
    var composed: [ComposedInsertion] { state.withLock { $0.composed } }
    var idleWaits: Int { state.withLock { $0.idleWaits } }

    func insert(restoreClipboard: Bool,
                compose: @escaping @Sendable (InsertionDestination) async -> ComposedInsertion) async -> InsertionOutcome {
        let destination = self.destination
        let insertion = await compose(destination)
        state.withLock { $0.composed.append(insertion) }
        if case .clipboard(let reason) = destination { return .leftOnClipboard(reason) }
        return insertion.text.isEmpty && !insertion.pressEnter ? .nothingToInsert : .inserted
    }

    /// A clipboard restore that never finishes, as a stuck transaction would. Its wait ignores cancellation, as the
    /// real inserter's does.
    var neverIdle: Bool {
        get { state.withLock { $0.neverIdle } }
        set { state.withLock { $0.neverIdle = newValue } }
    }

    func waitUntilIdle() async {
        let stuck = state.withLock { state in
            state.idleWaits += 1
            return state.neverIdle
        }
        guard stuck else { return }
        await withCheckedContinuation { continuation in state.withLock { $0.stuck.append(continuation) } }
    }

    /// Lets every stuck wait finish.
    func becomeIdle() {
        let waiting = state.withLock { state in
            defer { state.stuck = [] }
            return state.stuck
        }
        for continuation in waiting { continuation.resume() }
    }
}

struct GrantedMicrophone: MicrophoneAuthorizing {
    func current() -> MicrophoneAccess { .granted }
    func request() async -> MicrophoneAccess { .granted }
}

@MainActor
final class FakeFrontmost: FrontmostAppReading {
    var app: AppIdentity? = AppIdentity(bundleID: "com.example.fieldnotes", name: "Field Notes")
    func frontmostApp() -> AppIdentity? { app }
}

final class FakeReader: TextFieldReading {
    func isTrusted() -> Bool { false }
    func captureFocusedTextField() -> TextFieldTarget? { nil }
    func check(_ target: TextFieldTarget) -> TextFieldCheck { .failed }
    func characterCount(_ target: TextFieldTarget) -> Int? { nil }
    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? { nil }
    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? { nil }
}

final class FakeTrust: AccessibilityTrust {
    private let trusted: Mutex<Bool>
    init(_ trusted: Bool) { self.trusted = Mutex(trusted) }
    var isTrusted: Bool { trusted.withLock { $0 } }
    func changes() -> AsyncStream<Bool> {
        let value = isTrusted
        return AsyncStream { $0.yield(value) }
    }
}

@MainActor
@Observable
final class FakeShortcuts: ShortcutService {
    var status: ShortcutMonitor.Status = .stopped
    @ObservationIgnored weak var handler: (any TriggerHandling)?
    @ObservationIgnored var bindings: [[ShortcutAction: ShortcutBinding]] = []
    @ObservationIgnored var starts = 0
    @ObservationIgnored var stops = 0
    @ObservationIgnored var cancels = 0
    @ObservationIgnored var nextRecording: ShortcutBinding?
    @ObservationIgnored private var recording: CheckedContinuation<ShortcutBinding?, Never>?

    func start() {
        starts += 1
        status = .running
    }

    func stop() {
        stops += 1
        status = .stopped
    }

    func setBindings(_ bindings: [ShortcutAction: ShortcutBinding]) { self.bindings.append(bindings) }

    func recordBinding() async -> ShortcutBinding? {
        recording?.resume(returning: nil)
        return await withCheckedContinuation { recording = $0 }
    }

    /// Ends the recording in progress with `binding`.
    func press(_ binding: ShortcutBinding?) {
        recording?.resume(returning: binding)
        recording = nil
    }

    var isRecording: Bool { recording != nil }

    func cancelRecording() {
        cancels += 1
        press(nil)
    }
}

@MainActor
@Observable
final class FakeLoginItem: LoginItemControlling {
    var state: LoginItem.State = .disabled
    func refresh() {}
    func setEnabled(_ enabled: Bool) throws { state = enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}

struct FakeMicrophones: MicrophoneListing {
    let devices = [AudioInputDevice(id: "built-in", name: "Desk Microphone", isDefault: true)]
    func current() -> [AudioInputDevice] { devices }
    func changes() -> AsyncStream<[AudioInputDevice]> {
        let devices = self.devices
        return AsyncStream { $0.yield(devices) }
    }
}

/// Records what the pill was shown.
@MainActor
final class FakePill: PillPresenting {
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onNoticeAction: (UInt64, String) -> Void = { _, _ in }
    private(set) var shown: [PillDisplay] = []

    func show(_ display: PillDisplay) {
        if shown.last != display { shown.append(display) }
    }

    var current: PillDisplay { shown.last ?? .hidden }
}

/// What the windows asked the system to do.
@MainActor
final class SystemLog {
    var copied: [String] = []
    var opened: [URL] = []
    var grants = 0
}

/// The fakes together, and the composition over them in temporary directories.
@MainActor
final class Harness {
    let capture = FakeCapture()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let frontmost = FakeFrontmost()
    let shortcuts = FakeShortcuts()
    let login = FakeLoginItem()
    let pill = FakePill()
    let clock = ManualClock()
    let system = SystemLog()
    let app: AppComposition
    let windows: WindowModels

    /// `model`: a model directory for the vocabulary (`makeModelDirectory`); without one the dictionary cannot be
    /// edited and nothing is kept for a suggestion.
    init(directory: URL, defaults: UserDefaults, model: URL? = nil, trusted: Bool = true) {
        let info = AppInfo(name: "Sorello Test", version: "0.0.1", build: "1", modelDirectory: model,
                           modelName: model.flatMap(AppInfo.modelName(in:)))
        let system = self.system
        let platform = AppPlatform(
            capture: capture, microphone: GrantedMicrophone(), frontmostApp: frontmost, inserter: inserter,
            fieldReader: FakeReader(), accessibility: FakeTrust(trusted), shortcuts: shortcuts, loginItem: login,
            microphones: FakeMicrophones(), keyboard: { ShortcutFormatter(layout: NoKeys()) }, clock: clock,
            system: SystemActions(open: { system.opened.append($0) }, copy: { system.copied.append($0) },
                                  chooseApp: { nil }, grantAccessibility: { _ in system.grants += 1 },
                                  openMicrophoneSettings: {}))
        let speech = self.speech
        app = AppComposition(info: info, storage: AppStorage(paths: AppPaths(root: directory), defaults: defaults),
                             platform: platform, speech: { _ in speech }, pill: pill, levels: LevelFeed())
        windows = WindowModels(app: app)
    }

    /// Holds Hold to Talk, speaks `seconds` of audio, and lets go.
    func dictate(seconds: Double = 1.2) async {
        app.relay.handle(.holdPressed, at: clock.now)
        await eventually { if case .recording = self.app.runtime.state.capture { true } else { false } }
        capture.deliver(seconds: seconds, at: clock.now)
        clock.advance(by: seconds)
        app.relay.handle(.holdReleased(.keyUp), at: clock.now)
    }
}

/// A keyboard layout that types nothing.
struct NoKeys: KeyboardLayout {
    func characters(forKeyCode code: UInt16) -> String? { nil }
}

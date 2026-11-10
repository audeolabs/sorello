import AppKit
import DictationCore
import DictionaryKit
import Foundation
import MacPlatform
import Observation
import Synchronization

// The adapters the self-test and the snapshots use in place of the ones that reach outside the app: no event tap, no
// login item, no field reads, nothing on the pasteboard. They need no permission, so the whole app can be proven
// without one (ARCHITECTURE.md, section 11).

/// Plays recordings as a microphone would: 100 ms chunks at the pace they were spoken, stamped with the session's
/// clock, to whichever dictation starts next.
nonisolated final class FileCapture: AudioCapturing {
    /// One recording being played.
    final class Playback: AudioCapture {
        let events: AsyncStream<CaptureEvent>
        private let continuation: AsyncStream<CaptureEvent>.Continuation
        private let task = Mutex<Task<Void, Never>?>(nil)
        /// Finishes when every chunk has been delivered.
        let played: AsyncStream<Void>

        init(samples: [Float], clock: any SessionClock) {
            let (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
            self.events = events
            self.continuation = continuation
            let (played, done) = AsyncStream.makeStream(of: Void.self)
            self.played = played
            let piece = Int(AudioFormat.sampleRate) / 10
            let started = clock.now
            task.withLock {
                $0 = Task {
                    for (index, start) in stride(from: 0, to: samples.count, by: piece).enumerated() {
                        let due = started + Double(index + 1) * 0.1
                        do { try await clock.sleep(for: due - clock.now) } catch { break }
                        let chunk = Array(samples[start..<min(start + piece, samples.count)])
                        continuation.yield(.chunk(AudioChunk(samples: chunk, time: clock.now)))
                    }
                    done.finish()
                }
            }
        }

        func stop() async {
            await task.withLock { $0 }?.value
            continuation.finish()
        }

        func abort() {
            task.withLock { $0 }?.cancel()
            continuation.finish()
        }
    }

    private let clock: any SessionClock
    private let queued = Mutex<[[Float]]>([])
    private let current = Mutex<Playback?>(nil)

    init(clock: any SessionClock) {
        self.clock = clock
    }

    /// The next dictation hears `samples`.
    func queue(_ samples: [Float]) {
        queued.withLock { $0.append(samples) }
    }

    func start(_ request: CaptureRequest) async throws -> any AudioCapture {
        guard let samples = queued.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw CaptureFailure.noInputDevice
        }
        let playback = Playback(samples: samples, clock: clock)
        current.withLock { $0 = playback }
        return playback
    }

    /// Returns once the recording being played has been delivered in full, or at once if none is playing.
    func waitUntilPlayed() async {
        guard let playback = current.withLock({ $0 }) else { return }
        for await _ in playback.played {}
    }
}

/// Pastes nothing: composes for a cursor whose field could not be read, as a paste into an unreadable field is, and
/// keeps what would have been inserted.
nonisolated final class RecordingInserter: AppInserting {
    private let insertions = Mutex<[ComposedInsertion]>([])

    var inserted: [ComposedInsertion] { insertions.withLock { $0 } }

    func insert(restoreClipboard: Bool,
                compose: @escaping @Sendable (InsertionDestination) async -> ComposedInsertion) async -> InsertionOutcome {
        let insertion = await compose(.cursor(context: nil, field: nil))
        insertions.withLock { $0.append(insertion) }
        return insertion.text.isEmpty && !insertion.pressEnter ? .nothingToInsert : .inserted
    }

    func waitUntilIdle() async {}
}

/// Access the self-test does not ask for: the microphone is a file, and nothing is read from another app.
nonisolated struct FileMicrophone: MicrophoneAuthorizing {
    func current() -> MicrophoneAccess { .granted }
    func request() async -> MicrophoneAccess { .granted }
}

@MainActor
final class NoFrontmostApp: FrontmostAppReading {
    func frontmostApp() -> AppIdentity? { nil }
}

nonisolated final class NoFieldReader: TextFieldReading {
    func isTrusted() -> Bool { false }
    func captureFocusedTextField() -> TextFieldTarget? { nil }
    func check(_ target: TextFieldTarget) -> TextFieldCheck { .failed }
    func characterCount(_ target: TextFieldTarget) -> Int? { nil }
    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? { nil }
    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? { nil }
}

/// A fixed answer for Accessibility: the self-test never asks, and the snapshots show it granted.
nonisolated struct FixedTrust: AccessibilityTrust {
    let isTrusted: Bool
    func changes() -> AsyncStream<Bool> {
        let trusted = isTrusted
        return AsyncStream { $0.yield(trusted) }
    }
}

/// Shortcuts that never start: the self-test's hold is synthetic.
@MainActor
@Observable
final class NoShortcuts: ShortcutService {
    var status: ShortcutMonitor.Status = .stopped
    @ObservationIgnored weak var handler: (any TriggerHandling)?
    func start() {}
    func stop() {}
    func setBindings(_ bindings: [ShortcutAction: ShortcutBinding]) {}
    func recordBinding() async -> ShortcutBinding? { nil }
    func cancelRecording() {}
}

@MainActor
@Observable
final class NoLoginItem: LoginItemControlling {
    var state: LoginItem.State = .disabled
    func refresh() {}
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}

nonisolated struct FixedMicrophones: MicrophoneListing {
    let devices: [AudioInputDevice]
    func current() -> [AudioInputDevice] { devices }
    func changes() -> AsyncStream<[AudioInputDevice]> {
        let devices = self.devices
        return AsyncStream { $0.yield(devices) }
    }
}

extension AppPlatform {
    /// The platform for a mode that must reach nothing outside the app.
    static func quiet(capture: any AudioCapturing, inserter: any AppInserting, trusted: Bool,
                      microphones: [AudioInputDevice] = [], clock: any SessionClock) -> AppPlatform {
        AppPlatform(capture: capture, microphone: FileMicrophone(), frontmostApp: NoFrontmostApp(),
                    inserter: inserter, fieldReader: NoFieldReader(), accessibility: FixedTrust(isTrusted: trusted),
                    shortcuts: NoShortcuts(), loginItem: NoLoginItem(),
                    microphones: FixedMicrophones(devices: microphones),
                    keyboard: { ShortcutFormatter(layout: KeyboardLayoutSnapshot.current()) }, clock: clock,
                    system: SystemActions(open: { _ in }, copy: { _ in }, chooseApp: { nil },
                                          grantAccessibility: { _ in }, openMicrophoneSettings: {}))
    }
}

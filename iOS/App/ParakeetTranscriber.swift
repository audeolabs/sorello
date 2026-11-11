import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine
import Synchronization
import UIKit

/// One dictation's measurements for Diagnostics. Content-free and held in memory only.
struct DictationMeasurement: Identifiable, Sendable {
    typealias Outcome = TranscriptionEngine.AttemptReport.Outcome

    let id = UUID()
    var audioSeconds: Double
    /// Waiting for readiness, which includes preparation when the model was cold.
    var waitMilliseconds: Double
    var transcriptionMilliseconds: Double
    var computeUnits: String
    var inBackground: Bool
    var outcome: Outcome
    /// A content-free explanation of a failure, such as the iOS 27 background entitlement.
    var hint: ComputeFailureHint?
    var footprint: ProcessMemory.Footprint?
}

struct PreparationMeasurement: Sendable {
    var seconds: Double
    var computeUnits: String
    var inBackground: Bool
    var succeeded: Bool
    var footprint: ProcessMemory.Footprint?
}

/// The model runtime for SwiftUI and Diagnostics. The work is done by `TranscriptionEngine` (HostCore),
/// which the session core uses directly; this adds the runtime, the shared `SpeechEngine`, the persisted
/// preparation estimate and in-memory measurements.
@MainActor
final class ParakeetTranscriber: ObservableObject {
    static let maxMeasurements = 10

    let engine: TranscriptionEngine
    @Published private(set) var modelState: HostStatus.Model
    @Published private(set) var preparationStartedAt: Date?
    @Published private(set) var lastPreparation: PreparationMeasurement?
    @Published private(set) var measurements: [DictationMeasurement] = []
    /// The compute units of the loaded runtime, nil when none is loaded. Read-only: always the Neural Engine.
    @Published private(set) var activeUnits: ComputePolicy.Units?
    /// The hint of the most recent failed dictation, cleared by the next success. For Diagnostics.
    @Published private(set) var lastFailureHint: ComputeFailureHint?

    /// Called after every model state change, so the session publishes it to the keyboard.
    var onStateChange: (@MainActor () -> Void)?

    private let preferences: AppPreferences
    private let dictionary = DictionarySnapshotBox()

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let directory = CarriedModel.directory
        let dictionary = self.dictionary
        engine = TranscriptionEngine(
            isAvailable: directory != nil, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            isInBackground: { UIApplication.shared.applicationState == .background },
            makeRuntime: { ParakeetRuntime(units: ComputePolicy.units, directory: directory, dictionary: dictionary) })
        modelState = engine.modelState
        engine.onStateChange = { [weak self] in
            self?.sync()
            self?.onStateChange?()
        }
        engine.onPreparation = { [weak self] report in self?.recordPreparation(report) }
        engine.onAttempt = { [weak self] report in self?.recordAttempt(report) }
    }

    /// Seconds the last successful preparation took on this device, for a progress estimate.
    var estimatedPreparationSeconds: Double? { preferences.lastPreparationSeconds }

    /// The dictionary later transcriptions decode with; one already running keeps its snapshot.
    func useDictionary(_ snapshot: DictionarySnapshot) {
        dictionary.set(snapshot)
    }

    /// "Find strength" on the loaded model (contract: "Custom dictionary"). Not a dictation: no measurement.
    func probeStrength(samples: [Float], word: String) async throws -> StrengthProbe.Result {
        try await engine.withReadyRuntime { runtime in
            guard let runtime = runtime as? ParakeetRuntime else { throw TranscriptionFailure.modelUnavailable }
            return try await runtime.probeStrength(samples: samples, word: word)
        }
    }

    /// The user asked (Prepare, Retry, onboarding, "Find strength"): starts at once, even while a failed
    /// preparation backs off. The session core prepares through `engine` and respects the backoff.
    func prepare() {
        engine.retryPreparation()
        sync()
    }

    @discardableResult
    func releaseIfIdle() -> Bool {
        defer { sync() }
        return engine.releaseIfIdle()
    }

    private func sync() {
        if modelState != engine.modelState { modelState = engine.modelState }
        if preparationStartedAt != engine.preparationStartedAt { preparationStartedAt = engine.preparationStartedAt }
        let units = engine.isLoaded ? ComputePolicy.units : nil
        if activeUnits != units { activeUnits = units }
    }

    private func recordPreparation(_ report: TranscriptionEngine.PreparationReport) {
        let measurement = PreparationMeasurement(seconds: report.seconds, computeUnits: ComputePolicy.units.label,
                                                 inBackground: report.inBackground, succeeded: report.succeeded,
                                                 footprint: ProcessMemory.footprint())
        lastPreparation = measurement
        if report.succeeded { preferences.lastPreparationSeconds = report.seconds }
        sync()
        #if SORELLO_SELFTEST
        SelfTest.report(measurement)
        #endif
    }

    private func recordAttempt(_ report: TranscriptionEngine.AttemptReport) {
        let measurement = DictationMeasurement(
            audioSeconds: report.audioSeconds, waitMilliseconds: report.waitSeconds * 1_000,
            transcriptionMilliseconds: report.transcriptionSeconds * 1_000,
            computeUnits: ComputePolicy.units.label, inBackground: report.inBackground, outcome: report.outcome,
            hint: report.hint, footprint: ProcessMemory.footprint())
        switch report.outcome {
        case .transcribed: lastFailureHint = nil
        case .failed: lastFailureHint = report.hint
        case .cancelled: break
        }
        measurements.insert(measurement, at: 0)
        if measurements.count > Self.maxMeasurements { measurements.removeLast(measurements.count - Self.maxMeasurements) }
        #if SORELLO_SELFTEST
        SelfTest.report(measurement)
        #endif
    }
}

/// The model the app carries (ARCHITECTURE.md, "Transcription"), in `Model/`: the build the pin lists for iOS, which the
/// build checked against the pin and its manifest. The engine loads it where it lies and checks every file again. Nil
/// when the app was built without it, and on anything but arm64, as before.
enum CarriedModel {
    static var directory: URL? {
        #if arch(arm64)
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Model", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("bundle.json").path) else {
            return nil
        }
        return directory
        #else
        return nil
        #endif
    }
}

/// The shared `SpeechEngine` as a `SpeechRuntime`: the encoder's one 15 s function, to bound memory. Dropping the last
/// reference releases the engine and its model. The model loads where it lies in the app, with no store: a stable
/// copy (the Mac's store) does not survive iOS updates, because iOS compiles the Neural Engine program again for each
/// installed build (TestFlight 20 → 21 reused the copy's cache entry but still compiled).
///
/// The engine's failures become the app's own: a cancellation is a `CancellationError`, a failed preparation
/// `.modelFailed` and any other failure `.transcriptionFailed`, which `TranscriptionEngine` turns into the request's
/// error and the background hint. A request that ends early still waits for the model to let go of the chunk it is
/// working on, as it always has, so the runtime is never released or replaced under that work.
private final class ParakeetRuntime: SpeechRuntime {
    private let engine: SpeechEngine?
    private let dictionary: DictionarySnapshotBox

    init(units: ComputePolicy.Units, directory: URL?, dictionary: DictionarySnapshotBox) {
        self.dictionary = dictionary
        // The engine reads the snapshot when each transcription starts.
        engine = directory.map {
            SpeechEngine(modelDirectory: $0, storeDirectory: nil, compute: units.speechCompute,
                         dictionary: { _ in dictionary.current })
        }
    }

    func prepare() async throws {
        guard let engine else { throw TranscriptionFailure.modelUnavailable }
        await engine.prepare()
        // `prepare` returns once the attempt has ended, which the engine has published by then.
        var readiness = EngineReadiness.preparing
        for await current in engine.readiness() {
            readiness = current
            break
        }
        guard readiness == .ready else { throw TranscriptionFailure.modelFailed }
    }

    /// One snapshot per transcription, taken when it starts.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let engine else { throw TranscriptionFailure.modelUnavailable }
        do {
            return try await engine.transcribe(samples)
        } catch {
            await engine.waitUntilModelWorkEnds()
            throw Self.failure(error)
        }
    }

    /// "Find strength" with the current dictionary, minus the word.
    func probeStrength(samples: [Float], word: String) async throws -> StrengthProbe.Result {
        guard let engine else { throw TranscriptionFailure.modelUnavailable }
        do {
            return try await engine.probeStrength(samples: samples, word: word)
        } catch {
            throw Self.failure(error)
        }
    }

    /// The snapshot is taken now, on the main actor, so it is the one whose revision the stream keeps; `finish` fails,
    /// so the recording is transcribed as before, if the dictionary changed meanwhile.
    func beginStream(onEnd: @escaping @Sendable () -> Void) -> SpeechStream? {
        guard let engine else { return nil }
        let revision = dictionary.current.revision
        let stream = engine.openStream(SpeechStreamOptions())
        return ParakeetStream(stream: stream, engine: engine, revision: revision, dictionary: dictionary, onEnd: onEnd)
    }

    /// The app's error for one of the engine's.
    static func failure(_ error: Error) -> Error {
        (error as? SpeechFailure) == .cancelled ? CancellationError() : TranscriptionFailure.transcriptionFailed
    }
}

/// The engine's stream as a `SpeechStream`. Audio stays in memory. `onEnd` runs once, after `finish` or `cancel`, when
/// the engine has finished the model work the stream started.
private final class ParakeetStream: SpeechStream {
    private let stream: any SpeechStreaming
    private let engine: SpeechEngine
    private let revision: UInt64
    private let dictionary: DictionarySnapshotBox
    private let onEnd: @Sendable () -> Void
    private let ended = Mutex(false)

    init(stream: any SpeechStreaming, engine: SpeechEngine, revision: UInt64, dictionary: DictionarySnapshotBox,
         onEnd: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.engine = engine
        self.revision = revision
        self.dictionary = dictionary
        self.onEnd = onEnd
    }

    func append(_ samples: [Float]) { stream.append(samples) }

    func finish() async throws -> String {
        guard dictionary.current.revision == revision else {
            cancel()
            throw TranscriptionFailure.transcriptionFailed
        }
        defer { end() }
        do {
            return try await stream.finish().text
        } catch {
            throw ParakeetRuntime.failure(error)
        }
    }

    func cancel() {
        stream.cancel()
        end()
    }

    private func end() {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        let engine = self.engine, onEnd = self.onEnd
        Task {
            await engine.waitUntilModelWorkEnds()
            onEnd()
        }
    }
}

/// The current dictionary snapshot, set on the main actor and read when a transcription starts.
private final class DictionarySnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = DictionarySnapshot.empty

    var current: DictionarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func set(_ snapshot: DictionarySnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }
}

extension ComputeFailureHint {
    var message: String {
        switch self {
        case .backgroundNeuralEngineNeedsEntitlement:
            return "Transcription failed in the background. From iOS 27 the Neural Engine needs an entitlement this build does not have yet, so dictate with Sorello in the foreground for now."
        }
    }
}

extension ComputePolicy.Units {
    var speechCompute: SpeechCompute { self == .cpuOnly ? .cpu : .neuralEngine }
    var label: String { self == .cpuOnly ? "CPU" : "CPU + Neural Engine" }
}

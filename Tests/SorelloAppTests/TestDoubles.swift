import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine
import Synchronization
@testable import SorelloApp

// Test doubles with no platform behind them: a clock moved by hand and an engine that hears what it is told.

/// A clock the test moves by hand. Sleepers wake when the time passes their deadline.
final class ManualClock: SessionClock {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval = 1000
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = Mutex(State())

    var now: TimeInterval { state.withLock { $0.now } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // A task cancelled before it slept has already run its cancellation handler: it must not wait.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let resumeNow: Bool = state.withLock { state in
                    if seconds <= 0 { return true }
                    state.sleepers[id] = Sleeper(deadline: state.now + seconds, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on and wakes every sleeper whose deadline has passed.
    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = state.withLock { state in
            state.now += seconds
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
}

/// An engine that is ready at once, on `compute`, and hears what the test says it heard.
final class FakeSpeech: AppSpeech {
    let compute: SpeechCompute

    init(compute: SpeechCompute = .neuralEngine, readiness: EngineReadiness = .ready) {
        self.compute = compute
        state = Mutex(State(readiness: readiness))
    }

    final class Stream: SpeechStreaming {
        let result: SpeechResult
        init(result: SpeechResult) { self.result = result }
        func append(_ samples: [Float]) {}
        func finish() async throws -> SpeechResult { result }
        func cancel() {}
    }

    private struct State {
        var transcript = "hello world"
        var opened: [SpeechStreamOptions] = []
        var released: [UInt64] = []
        var discards = 0
        var checks = 0
        var suggestion: DictionarySuggestion?
        var retried = "a retried transcript"
        var retries = 0
        var readiness: EngineReadiness
        /// What the engine becomes when it is asked to prepare, one for each time it is asked, then the last for
        /// ever; empty leaves it as it is.
        var afterPrepares: [EngineReadiness] = []
        var prepares = 0
        var subscribers: [UUID: AsyncStream<EngineReadiness>.Continuation] = [:]
    }

    private let state: Mutex<State>

    var transcript: String {
        get { state.withLock { $0.transcript } }
        set { state.withLock { $0.transcript = newValue } }
    }
    var suggestion: DictionarySuggestion? {
        get { state.withLock { $0.suggestion } }
        set { state.withLock { $0.suggestion = newValue } }
    }
    /// What a Run Log retry hears.
    var retried: String {
        get { state.withLock { $0.retried } }
        set { state.withLock { $0.retried = newValue } }
    }
    /// How many Run Log retries reached the engine.
    var retries: Int { state.withLock { $0.retries } }
    var opened: [SpeechStreamOptions] { state.withLock { $0.opened } }
    var released: [UInt64] { state.withLock { $0.released } }
    var discards: Int { state.withLock { $0.discards } }
    var checks: Int { state.withLock { $0.checks } }

    /// How many times the engine was asked to prepare.
    var prepares: Int { state.withLock { $0.prepares } }

    /// What the engine becomes each next time it is asked to prepare: an attempt per value, the last repeated.
    var afterPrepares: [EngineReadiness] {
        get { state.withLock { $0.afterPrepares } }
        set { state.withLock { $0.afterPrepares = newValue } }
    }

    /// What the engine becomes every next time it is asked to prepare.
    var afterPrepare: EngineReadiness? {
        get { afterPrepares.last }
        set { afterPrepares = newValue.map { [$0] } ?? [] }
    }

    func prepare() async {
        let next = state.withLock { state -> EngineReadiness? in
            state.prepares += 1
            guard let first = state.afterPrepares.first else { return nil }
            if state.afterPrepares.count > 1 { state.afterPrepares.removeFirst() }
            return first
        }
        if let next { publish(next) }
    }

    /// Tells every subscriber the engine's readiness is now `readiness`.
    func publish(_ readiness: EngineReadiness) {
        state.withLock { state in
            state.readiness = readiness
            for continuation in state.subscribers.values { continuation.yield(readiness) }
        }
    }

    func readiness() -> AsyncStream<EngineReadiness> {
        let (stream, continuation) = AsyncStream<EngineReadiness>.makeStream()
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.readiness)
            state.subscribers[id] = continuation
        }
        return stream
    }

    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming {
        let text = state.withLock { state in
            state.opened.append(options)
            return state.transcript
        }
        return Stream(result: SpeechResult(text: text, correctionID: options.retainForCorrection ? 77 : nil))
    }

    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String {
        state.withLock { state in
            state.retries += 1
            return state.retried
        }
    }

    func correctionCheck(typed: String, edited: String, correctionID: UInt64, ignore: Set<DictionaryKey>,
                         isLast: Bool) -> @Sendable () async -> DictionarySuggestion? {
        let suggestion = state.withLock { state in
            state.checks += 1
            return state.suggestion
        }
        // As the engine does, a word whose key is to be ignored is never found.
        return { suggestion.flatMap { ignore.contains(DictionaryKey($0.word)) ? nil : $0 } }
    }

    func releaseCorrection(_ correctionID: UInt64) { state.withLock { $0.released.append(correctionID) } }

    func discardCorrection() { state.withLock { $0.discards += 1 } }
}

/// A download that goes where the test says, counting what it is asked to do. It opens no connection.
final class FakeDownload: ModelDownloading {
    private struct State {
        var current: ModelDownloadState
        var vocabulary: BPEEncoder?
        var starts = 0
        var cancels = 0
        var refreshes = 0
        var subscribers: [UUID: AsyncStream<ModelDownloadState>.Continuation] = [:]
    }

    let size: Int64 = 138_084_519
    private let state: Mutex<State>

    /// A download now in `current`, whose model brings `vocabulary` once it is installed.
    init(_ current: ModelDownloadState, vocabulary: BPEEncoder? = nil) {
        state = Mutex(State(current: current, vocabulary: vocabulary))
    }

    var current: ModelDownloadState { state.withLock { $0.current } }
    var starts: Int { state.withLock { $0.starts } }
    var cancels: Int { state.withLock { $0.cancels } }
    var refreshes: Int { state.withLock { $0.refreshes } }

    func states() -> AsyncStream<ModelDownloadState> {
        let (stream, continuation) = AsyncStream<ModelDownloadState>.makeStream()
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.current)
            state.subscribers[id] = continuation
        }
        return stream
    }

    /// Moves the download to `next` and tells every subscriber.
    func publish(_ next: ModelDownloadState) {
        state.withLock { state in
            state.current = next
            for continuation in state.subscribers.values { continuation.yield(next) }
        }
    }

    func start() { state.withLock { $0.starts += 1 } }
    func cancel() { state.withLock { $0.cancels += 1 } }
    func refresh() { state.withLock { $0.refreshes += 1 } }
    func vocabulary() -> BPEEncoder? { state.withLock { $0.current == .installed ? $0.vocabulary : nil } }
}

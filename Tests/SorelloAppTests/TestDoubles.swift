import DictationCore
import DictionaryKit
import Foundation
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

/// An engine that is ready at once and hears what the test says it heard.
final class FakeSpeech: AppSpeech {
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
    }

    private let state = Mutex(State())

    var transcript: String {
        get { state.withLock { $0.transcript } }
        set { state.withLock { $0.transcript = newValue } }
    }
    var suggestion: DictionarySuggestion? {
        get { state.withLock { $0.suggestion } }
        set { state.withLock { $0.suggestion = newValue } }
    }
    var opened: [SpeechStreamOptions] { state.withLock { $0.opened } }
    var released: [UInt64] { state.withLock { $0.released } }
    var discards: Int { state.withLock { $0.discards } }
    var checks: Int { state.withLock { $0.checks } }

    func prepare() async {}

    func readiness() -> AsyncStream<EngineReadiness> {
        AsyncStream { continuation in continuation.yield(.ready) }
    }

    func openStream(_ options: SpeechStreamOptions) -> any SpeechStreaming {
        let text = state.withLock { state in
            state.opened.append(options)
            return state.transcript
        }
        return Stream(result: SpeechResult(text: text, correctionID: options.retainForCorrection ? 77 : nil))
    }

    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String {
        state.withLock { $0.retried }
    }

    func correctionCheck(typed: String, edited: String, correctionID: UInt64, ignore: Set<DictionaryKey>,
                         isLast: Bool) -> @Sendable () async -> DictionarySuggestion? {
        let suggestion = state.withLock { state in
            state.checks += 1
            return state.suggestion
        }
        return { suggestion }
    }

    func releaseCorrection(_ correctionID: UInt64) { state.withLock { $0.released.append(correctionID) } }

    func discardCorrection() { state.withLock { $0.discards += 1 } }
}

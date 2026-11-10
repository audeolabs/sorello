import DictationCore
import DictionaryKit
import Foundation
import Synchronization

/// One dictation's audio on its way to the engine (ARCHITECTURE.md, section 4, "Speech"). The ingress is a lock, not
/// the engine, so `append` and `cancel` are plain calls that return at once from any thread, including the audio
/// thread. Samples are handed to the engine in the order they were appended: each drain takes everything appended so
/// far, so however the drains are scheduled the order holds.
final class SpeechStream: SpeechStreaming {
    let id: UInt64
    /// The dictionary as it was when the dictation started.
    let snapshot: DictionarySnapshot
    let retainsAudio: Bool
    private let engine: SpeechEngine

    private struct Ingress {
        var inbox: [Float] = []
        var drainScheduled = false
        var cancelled = false
        var finishing = false
        /// Audio was dropped because the model could not be had; the stream can only fail now.
        var failure: SpeechFailure?
        var waiter: CheckedContinuation<SpeechResult, any Error>?
    }

    private let ingress = Mutex(Ingress())

    init(id: UInt64, engine: SpeechEngine, snapshot: DictionarySnapshot, retainsAudio: Bool) {
        self.id = id
        self.engine = engine
        self.snapshot = snapshot
        self.retainsAudio = retainsAudio
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let schedule = ingress.withLock { state -> Bool in
            guard !state.cancelled, !state.finishing, state.failure == nil else { return false }
            state.inbox.append(contentsOf: samples)
            defer { state.drainScheduled = true }
            return !state.drainScheduled
        }
        if schedule { Task { await engine.drain(self) } }
    }

    func finish() async throws -> SpeechResult {
        let accepted = ingress.withLock { state -> Bool in
            let accepted = !state.cancelled && !state.finishing
            state.finishing = true
            return accepted
        }
        guard accepted else { throw SpeechFailure.cancelled }
        engine.cancelChecks()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechResult, any Error>) in
                let waiting = ingress.withLock { state -> Bool in
                    guard !state.cancelled else { return false }
                    state.waiter = continuation
                    return true
                }
                guard waiting else {
                    continuation.resume(throwing: SpeechFailure.cancelled)
                    return
                }
                Task { await engine.complete(self) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (first, waiter) = ingress.withLock { state in
            let first = !state.cancelled
            state.cancelled = true
            state.inbox = []
            defer { state.waiter = nil }
            return (first, state.waiter)
        }
        waiter?.resume(throwing: SpeechFailure.cancelled)
        if first { Task { await engine.forget(id) } }
    }

    var isCancelled: Bool { ingress.withLock { $0.cancelled } }

    var isFinishing: Bool { ingress.withLock { $0.finishing } }

    /// Why the stream can no longer succeed, if something already decided that.
    var failure: SpeechFailure? { ingress.withLock { $0.failure } }

    /// Drops what was appended and makes the stream fail with `failure` when it finishes. The first failure wins.
    func fail(_ failure: SpeechFailure) {
        ingress.withLock { state in
            state.inbox = []
            state.drainScheduled = false
            if state.failure == nil { state.failure = failure }
        }
    }

    /// Throws once the stream is cancelled; the engine calls it between model calls and decoder steps.
    var cancellationCheck: () throws -> Void {
        { [ingress = self] in if ingress.isCancelled { throw TranscriptionError.cancelled } }
    }

    /// Everything appended since the last call, in order.
    func takeInbox() -> [Float] {
        ingress.withLock { state in
            defer {
                state.inbox = []
                state.drainScheduled = false
            }
            return state.inbox
        }
    }

    /// Hands the waiting `finish` its outcome. False when nothing waits any more, because the stream was cancelled.
    func deliver(_ outcome: Result<SpeechResult, SpeechFailure>) -> Bool {
        guard let waiter = ingress.withLock({ state in
            defer { state.waiter = nil }
            return state.waiter
        }) else { return false }
        waiter.resume(with: outcome.mapError { $0 })
        return true
    }
}

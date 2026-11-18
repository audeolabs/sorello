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
    /// Compaction holds a bounded amount of the silence before the first speech (ARCHITECTURE.md, section 5).
    let boundsLeadingSilence: Bool
    /// Present only when the owner asked for progress (ARCHITECTURE.md, section 5, "Progress").
    let progress: AsyncStream<SpeechProgress>?
    private let engine: SpeechEngine

    private struct Ingress {
        var inbox: [Float] = []
        var drainScheduled = false
        var cancelled = false
        var finishing = false
        /// Audio was dropped because the model could not be had; the stream can only fail now.
        var failure: SpeechFailure?
        var waiter: CheckedContinuation<SpeechResult, any Error>?
        /// Feeds `progress` until the stream ends. Reports are yielded under the lock, so none follows a cancel.
        var reports: AsyncStream<SpeechProgress>.Continuation?
    }

    private let ingress: Mutex<Ingress>

    init(id: UInt64, engine: SpeechEngine, snapshot: DictionarySnapshot, retainsAudio: Bool, reportsProgress: Bool,
         boundsLeadingSilence: Bool = false) {
        self.id = id
        self.engine = engine
        self.snapshot = snapshot
        self.retainsAudio = retainsAudio
        self.boundsLeadingSilence = boundsLeadingSilence
        var ingress = Ingress()
        if reportsProgress {
            // Unbounded, so a report never waits for the consumer.
            let (stream, continuation) = AsyncStream<SpeechProgress>.makeStream(bufferingPolicy: .unbounded)
            progress = stream
            ingress.reports = continuation
        } else {
            progress = nil
        }
        self.ingress = Mutex(ingress)
    }

    deinit {
        ingress.withLock { $0.reports }?.finish()
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
                let refusal = ingress.withLock { state -> SpeechFailure? in
                    if state.cancelled { return .cancelled }
                    if let failure = state.failure { return failure }
                    state.waiter = continuation
                    return nil
                }
                if let refusal {
                    continuation.resume(throwing: refusal)
                    return
                }
                Task { await engine.complete(self) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (first, waiter, reports) = ingress.withLock { state in
            let first = !state.cancelled
            state.cancelled = true
            state.inbox = []
            defer {
                state.waiter = nil
                state.reports = nil
            }
            return (first, state.waiter, state.reports)
        }
        reports?.finish()
        waiter?.resume(throwing: SpeechFailure.cancelled)
        if first { Task { await engine.forget(id) } }
    }

    var isCancelled: Bool { ingress.withLock { $0.cancelled } }

    var isFinishing: Bool { ingress.withLock { $0.finishing } }

    /// Why the stream can no longer succeed, if something already decided that.
    var failure: SpeechFailure? { ingress.withLock { $0.failure } }

    /// Drops what was appended and makes the stream fail with `failure`. The first failure wins, and a `finish`
    /// already waiting gets it at once, whatever the engine is still waiting for.
    func fail(_ failure: SpeechFailure) {
        let (latched, waiter) = ingress.withLock { state in
            state.inbox = []
            state.drainScheduled = false
            if state.failure == nil { state.failure = failure }
            defer { state.waiter = nil }
            return (state.failure ?? failure, state.waiter)
        }
        endProgress()
        waiter?.resume(throwing: latched)
    }

    /// Hands the owner a report, unless the feed has ended (as a cancel ends it).
    func report(_ progress: SpeechProgress) {
        ingress.withLock { _ = $0.reports?.yield(progress) }
    }

    /// Ends the feed: the stream will report nothing more.
    func endProgress() {
        ingress.withLock { state in
            defer { state.reports = nil }
            return state.reports
        }?.finish()
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

    /// Hands the waiting `finish` its outcome, and ends the feed after `last`. False when nothing waits any more,
    /// because the stream was cancelled; then nothing is reported. Both are decided under one lock, so a cancel
    /// either wins over the result and the last report together or over neither.
    func deliver(_ outcome: Result<SpeechResult, SpeechFailure>, last: SpeechProgress? = nil) -> Bool {
        let (waiter, reports) = ingress.withLock { state in
            defer {
                state.waiter = nil
                state.reports = nil
            }
            if state.waiter != nil, let last { state.reports?.yield(last) }
            return (state.waiter, state.reports)
        }
        reports?.finish()
        guard let waiter else { return false }
        waiter.resume(with: outcome.mapError { $0 })
        return true
    }
}

import DictationCore
import Foundation
import Synchronization

/// What the engine reports while it transcribes a file (ARCHITECTURE.md, section 5, "Transcribing a file").
public enum FileSpeechProgress: Sendable, Equatable {
    /// The model is not ready yet; the file waits for it.
    case preparingModel
    /// Seconds of the file's audio read so far, never more than `length`, and the file's length in seconds as the
    /// file gives it.
    case transcribing(read: TimeInterval, length: TimeInterval)
}

/// Why the engine could not transcribe a file. Content-free: nothing here names the file or carries what it holds.
public enum FileSpeechFailure: Error, Sendable, Equatable {
    /// The file is not there, is a directory, or may not be read.
    case cannotOpen
    /// `AVAudioFile` cannot read it, it has no soundtrack, or it is damaged part way through.
    case unreadable
    /// The model could not be had: not on this Mac, damaged, or it would not load.
    case engineUnavailable(EngineFailure)
    /// The transcription itself failed.
    case failed
    /// The calling task was cancelled.
    case cancelled
}

/// Resumes a waiting caller exactly once, with whichever comes first: the value, or nil for a cancellation. Either
/// may arrive before the caller has started waiting.
final class ResumeOnce<Value: Sendable>: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Value?, Never>?
        var outcome: Value??
    }

    private let state = Mutex(State())

    /// Waits for `resume`, or returns at once if it has been called.
    func wait(_ continuation: CheckedContinuation<Value?, Never>) {
        let outcome = state.withLock { state -> Value?? in
            guard let outcome = state.outcome else {
                state.waiter = continuation
                return nil
            }
            return outcome
        }
        if let outcome { continuation.resume(returning: outcome) }
    }

    /// The first call wins; later ones do nothing.
    func resume(_ value: Value?) {
        let waiter = state.withLock { state -> CheckedContinuation<Value?, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = .some(value)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }
}

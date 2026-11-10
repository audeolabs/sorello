import Foundation
import DictationCore
import Synchronization
import Testing

// A manual clock and helpers for waiting on tasks in tests. Every wait in real time has a limit, so a transaction that
// goes wrong fails its test instead of hanging the run.

/// A clock that moves only when the test moves it.
final class ManualClock: SessionClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    var now: TimeInterval { state.withLock { $0.now } }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + max(seconds, 0),
                                                  continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The earliest deadline anyone is sleeping until, if anyone is.
    var pendingDeadline: TimeInterval? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    /// Waits, in real time, until someone sleeps on this clock and returns the earliest deadline. Records an issue and
    /// returns nil if nobody does within five seconds.
    func nextDeadline(sourceLocation: SourceLocation = #_sourceLocation) async -> TimeInterval? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(5) {
            if let deadline = pendingDeadline { return deadline }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Nobody slept on the clock", sourceLocation: sourceLocation)
        return nil
    }

    /// Moves time to `time` and wakes everyone whose deadline has come.
    func advance(to time: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = max(state.now, time)
            let due = state.sleepers.filter { $0.deadline <= state.now + 1e-9 }
            state.sleepers.removeAll { $0.deadline <= state.now + 1e-9 }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Waits for `task`, moving `clock` to each deadline as it comes, for tests where only the result matters. Nil, with a
/// recorded issue, if the task has not finished after ten seconds of real time.
func drive<Value: Sendable>(_ task: Task<Value, Never>, clock: ManualClock,
                            sourceLocation: SourceLocation = #_sourceLocation) async -> Value? {
    let done = Flag()
    let watcher = Task {
        _ = await task.value
        done.set()
    }
    let start = ContinuousClock.now
    while !done.isSet, ContinuousClock.now - start < .seconds(10) {
        if let deadline = clock.pendingDeadline {
            clock.advance(to: deadline)
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    guard done.isSet else {
        Issue.record("The task did not finish", sourceLocation: sourceLocation)
        return nil
    }
    await watcher.value
    return await task.value
}

/// A flag that can be set from any task.
final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }
}

/// The value of `task`, or nil with a recorded issue if it does not finish within five seconds of real time, so a
/// transaction that goes wrong fails its test instead of hanging the run.
func finished<Value: Sendable>(_ task: Task<Value, Never>,
                               sourceLocation: SourceLocation = #_sourceLocation) async -> Value? {
    let result = Box<Value>()
    let watcher = Task { result.set(await task.value) }
    let start = ContinuousClock.now
    while result.value == nil, ContinuousClock.now - start < .seconds(5) {
        try? await Task.sleep(for: .milliseconds(1))
    }
    guard let value = result.value else {
        Issue.record("The task did not finish", sourceLocation: sourceLocation)
        return nil
    }
    await watcher.value
    return value
}

/// A value that can be set from any task.
final class Box<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    var value: Value? { stored.withLock { $0 } }

    func set(_ value: Value) { stored.withLock { $0 = value } }
}

/// Cancels the task that is running the caller.
func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

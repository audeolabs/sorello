import DictationCore
import Foundation
import Synchronization

/// A `SessionClock` that moves only when a test advances it. Sleepers wake, in deadline order, when the clock
/// reaches their deadline; a cancelled sleeper throws `CancellationError`.
final class TestClock: SessionClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TimeInterval
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
    }

    private let state: Mutex<State>

    init(now: TimeInterval = 1_000) {
        state = Mutex(State(now: now))
    }

    var now: TimeInterval { state.withLock { $0.now } }

    /// How many tasks are asleep on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if seconds <= 0 { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + seconds, continuation: continuation))
                    return nil
                }
                if let resume { continuation.resume(with: resume) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and wakes every sleeper whose deadline has come.
    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += seconds
            let due = state.sleepers.filter { $0.deadline <= state.now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits, in real time, until at least `count` tasks are asleep on the clock.
    func waitForSleepers(_ count: Int = 1) async {
        for _ in 0..<2_000 where sleeperCount < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

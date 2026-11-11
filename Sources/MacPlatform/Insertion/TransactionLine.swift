/// Lets insertion transactions through one at a time, in the order they asked. A transaction holds its turn from
/// `enter` until `leave`, which comes after its Return and its restore, so the next one never sees the clipboard
/// half put back.
actor TransactionLine {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busy = false
    private var waiting: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextID: UInt64 = 0

    /// Waits for this caller's turn. Returns false, without taking a turn, if the calling task is cancelled while it
    /// waits.
    func enter() async -> Bool {
        if !busy, waiting.isEmpty {
            busy = true
            return true
        }
        let id = nextID
        nextID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    /// Ends the current turn and hands it to the next caller in line.
    func leave() {
        if waiting.isEmpty {
            busy = false
            let idle = idleWaiters
            idleWaiters = []
            for waiter in idle { waiter.resume() }
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Returns once no transaction holds a turn or waits for one.
    func waitUntilIdle() async {
        guard busy || !waiting.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// A waiter whose task was cancelled leaves the line. One that already has its turn keeps it.
    private func withdraw(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

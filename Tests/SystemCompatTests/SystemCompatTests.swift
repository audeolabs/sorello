import Foundation
import SystemCompat
import Testing

/// What the rest of Sorello relies on from `Mutex` and `SerialActorQueue`, whichever build supplies them: Apple's own
/// in the usual build, the stand-ins in the build for older Macs (ARCHITECTURE.md, section 15).
@Suite struct SystemCompatTests {
    private enum Refusal: Error, Equatable { case odd }

    @Test("A mutex lets one caller at a time change its value")
    func mutexExcludes() async {
        let total = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<500 { total.withLock { $0 += 1 } }
                }
            }
        }
        #expect(total.withLock { $0 } == 32_000)
    }

    @Test("A mutex hands back what the closure returns, and throws what it throws, as its own type")
    func mutexReturnsAndThrows() {
        func halve(_ box: borrowing Mutex<Int>) throws(Refusal) -> Int {
            try box.withLock { value throws(Refusal) in
                guard value.isMultiple(of: 2) else { throw Refusal.odd }
                value /= 2
                return value
            }
        }
        let box = Mutex(12)
        #expect((try? halve(box)) == 6)
        #expect((try? halve(box)) == 3)
        #expect(throws: Refusal.odd) { try halve(box) }
        // A throw leaves the lock free and the value as the closure left it.
        #expect(box.withLock { $0 } == 3)
    }

    private actor Counter {
        static let label = "sorello.test.serial-actor-queue"
        private let queue = SerialActorQueue(label: Counter.label, qos: .utility)
        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
        private var steps: [Int] = []

        func step(_ number: Int) -> String {
            steps.append(number)
            return String(cString: __dispatch_queue_get_label(nil))
        }

        /// Resumes once everything that was waiting on the queue has run.
        func drained() async -> [Int] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
            return steps
        }
    }

    @Test("An actor on a serial actor queue runs its work on that queue")
    func actorRunsOnItsQueue() async {
        let counter = Counter()
        #expect(await counter.step(1) == Counter.label)
    }

    @Test("Work sent to the queue directly waits its turn behind the actor's")
    func queueKeepsOrder() async {
        let counter = Counter()
        for number in 0..<200 { _ = await counter.step(number) }
        #expect(await counter.drained() == Array(0..<200))
    }
}

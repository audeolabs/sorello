import Foundation

/// `KeyboardWorkLine`: the in-keyboard engine is used only once every earlier attempt's end and every release have
/// ended, and an attempt cancelled while it waits gets nothing and never holds up what is queued behind it.
enum KeyboardWorkLineTests {
    static var tests: [TestCase] {
        [
            ("aWaiterWaitsForEverythingQueued", isolated(testAWaiterWaitsForEverythingQueued)),
            ("workQueuedWhileWaitingIsAwaitedToo", isolated(testWorkQueuedWhileWaitingIsAwaitedToo)),
            ("aCancelledWaiterNeverHoldsUpTheNext", isolated(testACancelledWaiterNeverHoldsUpTheNext)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// A gate a piece of queued work waits on, opened by the test.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Outcome {
        var free: Bool?
    }

    @MainActor
    private static func wait(on line: KeyboardWorkLine) -> (Task<Void, Never>, Outcome) {
        let outcome = Outcome()
        let task = Task { @MainActor in outcome.free = await line.waitUntilFree() }
        return (task, outcome)
    }

    @MainActor
    private static func testAWaiterWaitsForEverythingQueued() {
        let line = KeyboardWorkLine()
        let (_, empty) = wait(on: line)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { empty.free != nil }, "an empty line kept a waiter")
        TestSupport.expectEqual(empty.free, true)
        let gate = Gate()
        line.then { await gate.wait() }
        let (_, waiter) = wait(on: line)
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(waiter.free, nil)
        gate.open()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { waiter.free != nil }, "the waiter never got the line")
        TestSupport.expectEqual(waiter.free, true)
    }

    @MainActor
    private static func testWorkQueuedWhileWaitingIsAwaitedToo() {
        let line = KeyboardWorkLine()
        let first = Gate(), second = Gate()
        line.then { await first.wait() }
        let (_, waiter) = wait(on: line)
        _ = TestSupport.waitUntil(timeout: 0.05) { false }
        // A release queued while the waiter waits.
        line.then { await second.wait() }
        first.open()
        _ = TestSupport.waitUntil(timeout: 0.1) { false }
        TestSupport.expectEqual(waiter.free, nil)
        second.open()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { waiter.free != nil }, "the waiter never got the line")
        TestSupport.expectEqual(waiter.free, true)
    }

    /// B waits behind A; B is cancelled and its end is queued behind it (waiting for B's task). When A ends, B gives up
    /// instead of waiting for its own end, so C gets the line.
    @MainActor
    private static func testACancelledWaiterNeverHoldsUpTheNext() {
        let line = KeyboardWorkLine()
        let a = Gate()
        line.then { await a.wait() }
        let (b, bOutcome) = wait(on: line)
        _ = TestSupport.waitUntil(timeout: 0.05) { false }
        b.cancel()
        line.then { await b.value }
        let (_, c) = wait(on: line)
        a.open()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { bOutcome.free != nil }, "the cancelled waiter kept waiting")
        TestSupport.expectEqual(bOutcome.free, false)
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { c.free != nil }, "the next waiter was held up")
        TestSupport.expectEqual(c.free, true)
        // Cancelled before it waits: nothing at once.
        let (late, lateOutcome) = wait(on: line)
        late.cancel()
        TestSupport.expect(TestSupport.waitUntil(timeout: 2) { lateOutcome.free != nil }, "a cancelled waiter never returned")
    }
}

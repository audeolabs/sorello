import Foundation

#if SORELLO_LEGACY
/// A serial dispatch queue an actor runs on: `DispatchSerialQueue` for systems before macOS 14, where a dispatch
/// queue cannot be an actor's executor. The actor's work, and whatever is sent to the queue directly, runs one piece
/// at a time in the order it arrived.
// Safe: the queue is immutable after `init`, and a dispatch queue may be used from any thread.
public final class SerialActorQueue: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .unspecified) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    public func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }

    /// Runs `work` on the queue after everything already waiting there.
    public func async(execute work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}
#else
public typealias SerialActorQueue = DispatchSerialQueue
#endif

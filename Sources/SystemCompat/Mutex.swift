// What Sorello takes from the system that macOS 13 does not have (ARCHITECTURE.md, section 15). In the usual build
// each name here is Apple's own type; in the build for older Macs it is a stand-in with the same name and the same
// calls, so the code that uses it is one text for both.

#if SORELLO_LEGACY
import Foundation

/// A value that is read and written only under its lock: `Synchronization.Mutex` for systems before macOS 15, which
/// do not have it. It has the initializer and the `withLock` the rest of Sorello calls, and nothing else.
// Safe: `value` is read and written only inside `withLock`, which holds `lock` for the whole of the caller's closure.
public final class Mutex<Value>: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value: Value

    public init(_ initialValue: consuming sending Value) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        value = initialValue
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Runs `body` with the value, alone: no other caller's `body` runs until this one returns or throws. As with
    /// Apple's lock, calling it again from inside `body` is an error the system stops the process for.
    public func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
    ) throws(Failure) -> sending Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&value)
    }
}
#else
import Synchronization

public typealias Mutex<Value: ~Copyable> = Synchronization.Mutex<Value>
#endif

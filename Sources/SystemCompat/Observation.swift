// Observation, for the classes Sorello marks @Observable. In the usual build this is Apple's Observation and nothing
// else. macOS 13 has no Observation, so the build for older Macs keeps the same source text and gives it another
// meaning (ARCHITECTURE.md, section 15):
//
// - `@Observable` is the toolchain's own macro, declared again without its macOS 14 floor, and only for the one thing
//   it does to the class's members: it marks each stored property that is not `@ObservationIgnored`. Each module
//   that has such classes declares it, in its `ObservationStandIn.swift`, because a name declared where it is used
//   wins over the one SwiftUI and other frameworks bring in.
// - Each mark expands, as it always does, into accessors that call `access`, `withMutation`,
//   `shouldNotifyObservers` and `_$observationRegistrar` on the object. Apple's macro would add those members; here
//   the `Observable` protocol below supplies them, and they send `objectWillChange`.
// - So an `@Observable` class that says it conforms to `Observable` is, in this build, an `ObservableObject` that
//   announces a change to any tracked property, once, before it happens, and not when an `Equatable` value is set to
//   what it already was. SwiftUI on macOS 13 follows it as it follows any `ObservableObject`.
//
// The macros come with the compiler, not with the system, so this needs nothing macOS 13 lacks. It does depend on
// what the compiler's macro expands to; `Tests/SystemCompatTests` holds that contract, and a compiler that changed
// it would fail this build or those tests, not the usual build.

#if SORELLO_LEGACY
import Combine
import Foundation

/// What an `@Observable` class is in this build: an object that announces its changes through `objectWillChange`.
public protocol Observable: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {}

/// Stands where the macro expects the object's registrar, for a property changed in place.
public struct ObservationRegistrarStandIn<Subject: Observable> {
    public func willSet<Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
        subject.objectWillChange.send()
    }

    public func didSet<Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {}
}

extension Observable {
    public nonisolated func access<Member>(keyPath: KeyPath<Self, Member>) {
        ObservationTracking.noteRead(of: self)
    }

    public nonisolated func withMutation<Member, Result>(
        keyPath: KeyPath<Self, Member>, _ mutation: () throws -> Result
    ) rethrows -> Result {
        objectWillChange.send()
        return try mutation()
    }

    public nonisolated func shouldNotifyObservers<Member>(_ old: Member, _ new: Member) -> Bool { true }
    public nonisolated func shouldNotifyObservers<Member: Equatable>(_ old: Member, _ new: Member) -> Bool { old != new }
    public nonisolated func shouldNotifyObservers<Member: AnyObject>(_ old: Member, _ new: Member) -> Bool { old !== new }
    public nonisolated func shouldNotifyObservers<Member: Equatable & AnyObject>(_ old: Member, _ new: Member) -> Bool {
        old != new
    }

    public nonisolated var _$observationRegistrar: ObservationRegistrarStandIn<Self> { ObservationRegistrarStandIn() }
}

/// Which objects a `withObservationTracking` closure read, kept for the thread that is running it.
enum ObservationTracking {
    private static let key = "sorello.observation-tracking"

    final class Reads {
        var publishers: [ObjectIdentifier: ObservableObjectPublisher] = [:]
    }

    static func noteRead<Subject: Observable>(of subject: Subject) {
        guard let reads = Thread.current.threadDictionary[key] as? Reads else { return }
        reads.publishers[ObjectIdentifier(subject)] = subject.objectWillChange
    }

    static func collect<Result>(_ apply: () -> Result) -> (Result, [ObservableObjectPublisher]) {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[key]
        let reads = Reads()
        dictionary[key] = reads
        defer { dictionary[key] = outer }
        let result = apply()
        // What an inner call read, the outer one read too.
        if let outer = outer as? Reads { outer.publishers.merge(reads.publishers) { first, _ in first } }
        return (result, Array(reads.publishers.values))
    }
}

/// Runs `apply`, then calls `onChange` once, the first time any object `apply` read a tracked property of is about to
/// change. As with Observation's function of this name, `onChange` runs before the change and on whatever thread
/// makes it. Unlike it, a change to any tracked property of an object that was read counts, not only to the
/// properties read.
public func withObservationTracking<Result>(_ apply: () -> Result, onChange: @autoclosure () -> @Sendable () -> Void) -> Result {
    let (result, publishers) = ObservationTracking.collect(apply)
    let changed = onChange()
    let watch = FirstChange()
    for publisher in publishers {
        watch.hold(publisher.sink {
            if watch.take() { changed() }
        })
    }
    return result
}

/// The subscriptions of one `withObservationTracking` call. The first change takes them all, which ends them.
// Safe: `subscriptions` is read and written only while `lock` is held.
private final class FirstChange: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [AnyCancellable]? = []

    func hold(_ subscription: AnyCancellable) {
        lock.lock()
        defer { lock.unlock() }
        subscriptions?.append(subscription)
    }

    /// True for the first caller only. The subscriptions are let go after the lock is.
    func take() -> Bool {
        lock.lock()
        let taken = subscriptions
        subscriptions = nil
        lock.unlock()
        return taken != nil
    }
}
#else
@_exported import Observation
#endif

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
// - `withObservationTracking` follows the properties its closure read, as Observation's does: each object keeps who
//   read which of its properties, and tells them before that property changes.
//
// The macros come with the compiler, not with the system, so this needs nothing macOS 13 lacks. It does depend on
// what the compiler's macro expands to; `Tests/SystemCompatTests` holds that contract, and a compiler that changed
// it would fail this build or those tests, not the usual build.

#if SORELLO_LEGACY
import Combine
import Foundation

/// What an `@Observable` class is in this build: an object that announces its changes through `objectWillChange`,
/// and to whoever read the changing property inside `withObservationTracking`.
public protocol Observable: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {}

/// Stands where the macro expects the object's registrar, for a property changed in place.
public struct ObservationRegistrarStandIn<Subject: Observable> {
    public func willSet<Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
        subject.announce(keyPath)
    }

    public func didSet<Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {}
}

extension Observable {
    public nonisolated func access<Member>(keyPath: KeyPath<Self, Member>) {
        ObservationTracking.noteRead(of: self, keyPath: keyPath)
    }

    public nonisolated func withMutation<Member, Result>(
        keyPath: KeyPath<Self, Member>, _ mutation: () throws -> Result
    ) rethrows -> Result {
        announce(keyPath)
        return try mutation()
    }

    public nonisolated func shouldNotifyObservers<Member>(_ old: Member, _ new: Member) -> Bool { true }
    public nonisolated func shouldNotifyObservers<Member: Equatable>(_ old: Member, _ new: Member) -> Bool { old != new }
    public nonisolated func shouldNotifyObservers<Member: AnyObject>(_ old: Member, _ new: Member) -> Bool { old !== new }
    public nonisolated func shouldNotifyObservers<Member: Equatable & AnyObject>(_ old: Member, _ new: Member) -> Bool {
        old != new
    }

    public nonisolated var _$observationRegistrar: ObservationRegistrarStandIn<Self> { ObservationRegistrarStandIn() }

    /// A tracked property is about to change: SwiftUI hears of it, and so does whoever read that property.
    fileprivate nonisolated func announce(_ keyPath: AnyKeyPath) {
        objectWillChange.send()
        Followers.of(self, makingThem: false)?.willChange(keyPath)
    }
}

/// One `withObservationTracking` call's interest in the properties it read. The first of them to change takes it.
// Safe: `onChange` is read and cleared only while `lock` is held.
private final class FirstChange: @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    var isTaken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onChange == nil
    }

    /// Calls `onChange` for the first caller only.
    func fire() {
        lock.lock()
        let taken = onChange
        onChange = nil
        lock.unlock()
        taken?()
    }
}

/// Who is following one object, by the property each read. The object keeps it, so it goes when the object does.
// Safe: `byProperty` is read and written only while `lock` is held.
private final class Followers: @unchecked Sendable {
    private let lock = NSLock()
    private var byProperty: [AnyKeyPath: [FirstChange]] = [:]

    func add(_ change: FirstChange, for keyPath: AnyKeyPath) {
        lock.lock()
        defer { lock.unlock() }
        // Interests another property's change already took are dropped here, so they never pile up.
        byProperty[keyPath, default: []].removeAll { $0.isTaken }
        byProperty[keyPath, default: []].append(change)
    }

    func willChange(_ keyPath: AnyKeyPath) {
        lock.lock()
        let interested = byProperty.removeValue(forKey: keyPath) ?? []
        lock.unlock()
        for change in interested { change.fire() }
    }

    private static let making = NSLock()
    // Safe: used only as the address that names the association.
    private nonisolated(unsafe) static var key: UInt8 = 0

    static func of(_ subject: AnyObject, makingThem: Bool) -> Followers? {
        making.lock()
        defer { making.unlock() }
        if let followers = objc_getAssociatedObject(subject, &key) as? Followers { return followers }
        guard makingThem else { return nil }
        let followers = Followers()
        objc_setAssociatedObject(subject, &key, followers, .OBJC_ASSOCIATION_RETAIN)
        return followers
    }
}

/// Which properties a `withObservationTracking` closure read, kept for the thread that is running it.
enum ObservationTracking {
    private static let key = "sorello.observation-tracking"

    final class Reads {
        var properties: [(subject: AnyObject, keyPath: AnyKeyPath)] = []
    }

    static func noteRead(of subject: AnyObject, keyPath: AnyKeyPath) {
        guard let reads = Thread.current.threadDictionary[key] as? Reads else { return }
        reads.properties.append((subject, keyPath))
    }

    static func collect<Result>(_ apply: () -> Result) -> (Result, Reads) {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[key]
        let reads = Reads()
        dictionary[key] = reads
        defer { dictionary[key] = outer }
        let result = apply()
        // What an inner call read, the outer one read too.
        (outer as? Reads)?.properties.append(contentsOf: reads.properties)
        return (result, reads)
    }
}

/// Runs `apply`, then calls `onChange` once, the first time any tracked property `apply` read is about to change. As
/// with Observation's function of this name, `onChange` runs before the change, on whatever thread makes it.
public func withObservationTracking<Result>(_ apply: () -> Result, onChange: @autoclosure () -> @Sendable () -> Void) -> Result {
    let (result, reads) = ObservationTracking.collect(apply)
    guard !reads.properties.isEmpty else { return result }
    let change = FirstChange(onChange())
    for (subject, keyPath) in reads.properties {
        Followers.of(subject, makingThem: true)?.add(change, for: keyPath)
    }
    return result
}
#else
@_exported import Observation
#endif

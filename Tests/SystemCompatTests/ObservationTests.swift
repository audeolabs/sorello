import Foundation
import SystemCompat
import Testing
#if SORELLO_LEGACY
import Combine
#endif

/// What Sorello relies on from an `@Observable` class, in both builds (ARCHITECTURE.md, section 15): Apple's
/// Observation in the usual one, the stand-in over `ObservableObject` in the build for older Macs. The last test
/// holds the stand-in to what it adds: it publishes as an `ObservableObject`, which is how SwiftUI follows it there.
@Observable
private final class Tally: Observable {
    struct Pair: Equatable { var left = 0, right = 0 }

    var count = 0
    var label = "a"
    var pair = Pair()
    var items: [Int] = []
    @ObservationIgnored var note = 0
    @ObservationIgnored let fixed = 1
    private(set) var steps = 0

    func step() { steps += 1 }
}

@Suite struct ObservationTests {
    /// How many times `onChange` ran for one `withObservationTracking` over `read`, across `changes`.
    private func announcements(reading read: (Tally) -> Void, _ changes: (Tally) -> Void) -> Int {
        let tally = Tally()
        let count = Mutex(0)
        withObservationTracking { read(tally) } onChange: { count.withLock { $0 += 1 } }
        changes(tally)
        return count.withLock { $0 }
    }

    @Test("A change to a property that was read is announced")
    func aReadPropertyIsFollowed() {
        #expect(announcements(reading: { _ = $0.count }, { $0.count = 1 }) == 1)
        #expect(announcements(reading: { _ = $0.steps }, { $0.step() }) == 1)
    }

    @Test("A property changed in place is announced")
    func inPlaceChangesAreFollowed() {
        #expect(announcements(reading: { _ = $0.pair }, { $0.pair.left = 3 }) == 1)
        #expect(announcements(reading: { _ = $0.items }, { $0.items.append(4) }) == 1)
    }

    @Test("Only the first change after the read is announced")
    func oneAnnouncementForEachRead() {
        #expect(announcements(reading: { _ = $0.count }, { $0.count = 1; $0.count = 2; $0.label = "b" }) == 1)
    }

    @Test("Setting a value to what it already was is not a change")
    func anEqualValueIsQuiet() {
        #expect(announcements(reading: { _ = $0.count; _ = $0.label }, { $0.count = 0; $0.label = "a" }) == 0)
    }

    @Test("An ignored property is not followed, and nothing read means nothing followed")
    func ignoredAndUnreadAreQuiet() {
        #expect(announcements(reading: { _ = $0.note; _ = $0.fixed }, { $0.note = 5 }) == 0)
        #expect(announcements(reading: { _ in }, { $0.count = 1 }) == 0)
    }

    @Test("The announcement comes before the change")
    func announcedBeforeTheChange() {
        let tally = Tally()
        let seen = Mutex<Int?>(nil)
        // Safe to read here: the closure runs inside the assignment below, on this thread.
        nonisolated(unsafe) let watched = tally
        withObservationTracking { _ = tally.count } onChange: { seen.withLock { $0 = watched.count } }
        tally.count = 7
        #expect(seen.withLock { $0 } == 0)
    }

    @Test("Only the properties that were read are followed")
    func unreadPropertiesAreQuiet() {
        #expect(announcements(reading: { _ = $0.count }, { $0.label = "b" }) == 0)
        #expect(announcements(reading: { _ = $0.count }, { $0.label = "b"; $0.count = 1 }) == 1)
    }

    @Test("Two objects are followed apart")
    func objectsAreFollowedApart() {
        let other = Tally()
        #expect(announcements(reading: { _ = $0.count }, { _ in other.count = 9 }) == 0)
    }

    #if SORELLO_LEGACY
    @Test("In the build for older Macs an observable class is an ObservableObject that publishes each change once")
    func publishesAsAnObservableObject() {
        let tally = Tally()
        var fired = 0
        let watch = tally.objectWillChange.sink { fired += 1 }
        tally.count = 1
        tally.count = 1
        tally.pair.right = 2
        tally.items.append(1)
        tally.step()
        tally.note = 9
        _ = tally.count
        watch.cancel()
        #expect(fired == 4)
    }
    #endif
}

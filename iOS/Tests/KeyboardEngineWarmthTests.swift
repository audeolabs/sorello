import Foundation

/// `KeyboardEngineWarmth`: the record's cold or warm (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Record,
/// "whether the engine was already loaded (warm) or not (cold)"; Transcription, the engine released after its work).
enum KeyboardEngineWarmthTests {
    static var tests: [TestCase] {
        [
            ("aNewEngineIsColdUntilPrepared", testANewEngineIsColdUntilPrepared),
            ("aFailedPreparationIsNeverWarm", testAFailedPreparationIsNeverWarm),
            ("aQueuedReleaseIsColdAtOnce", testAQueuedReleaseIsColdAtOnce),
            ("aTapBeforeAReleaseFinishesIsCold", testATapBeforeAReleaseFinishesIsCold),
            ("anOldReleaseLeavesANewerEngineAlone", testAnOldReleaseLeavesANewerEngineAlone),
        ]
    }

    /// Stand-ins for engines: only their identity matters.
    private final class Engine {}

    private static func testANewEngineIsColdUntilPrepared() {
        var warmth = KeyboardEngineWarmth()
        TestSupport.expect(!warmth.isWarm, "no engine is warm")
        let engine = Engine()
        warmth.made(ObjectIdentifier(engine))
        TestSupport.expectEqual(warmth.engine, ObjectIdentifier(engine))
        TestSupport.expect(!warmth.isWarm, "a new, unprepared engine is warm")
        warmth.prepared(ObjectIdentifier(engine))
        TestSupport.expect(warmth.isWarm, "a prepared engine is cold")
        // A new engine starts cold again.
        let next = Engine()
        warmth.made(ObjectIdentifier(next))
        TestSupport.expect(!warmth.isWarm, "a new engine inherited the last one's preparation")
    }

    /// An engine whose preparation failed is never prepared, and a preparation reported for another engine counts
    /// for nothing.
    private static func testAFailedPreparationIsNeverWarm() {
        var warmth = KeyboardEngineWarmth()
        let engine = Engine(), other = Engine()
        warmth.made(ObjectIdentifier(engine))
        TestSupport.expect(!warmth.isWarm, "a failed preparation is warm")
        warmth.prepared(ObjectIdentifier(other))
        TestSupport.expect(!warmth.isWarm, "another engine's preparation warmed this one")
    }

    /// `release()` queues the release behind the engine's work: from the moment it is asked for, a tap is cold, though
    /// the engine is still loaded until its drain ends.
    private static func testAQueuedReleaseIsColdAtOnce() {
        var warmth = KeyboardEngineWarmth()
        let engine = Engine()
        warmth.made(ObjectIdentifier(engine))
        warmth.prepared(ObjectIdentifier(engine))
        warmth.releaseRequested(ObjectIdentifier(engine))
        TestSupport.expect(!warmth.isWarm, "a release still draining left the engine warm")
        TestSupport.expectEqual(warmth.engine, ObjectIdentifier(engine))
        TestSupport.expect(warmth.released(ObjectIdentifier(engine)), "the release did not release its engine")
        TestSupport.expectEqual(warmth.engine, nil)
        TestSupport.expect(!warmth.isWarm, "no engine is warm")
        // Nothing to release: nothing happens.
        warmth.releaseRequested(nil)
        TestSupport.expect(!warmth.released(nil), "a release of no engine released one")
    }

    /// Attempt A is cancelled while its model work drains; an idle memory warning releases the engine; B is tapped
    /// before that release finishes. B is recorded cold.
    private static func testATapBeforeAReleaseFinishesIsCold() {
        var warmth = KeyboardEngineWarmth()
        let engine = Engine()
        warmth.made(ObjectIdentifier(engine))
        warmth.prepared(ObjectIdentifier(engine))
        TestSupport.expect(warmth.isWarm, "A's prepared engine is cold")
        // A cancelled: its drain is queued; the engine stays loaded and prepared.
        TestSupport.expect(warmth.isWarm, "cancelling A alone made the engine cold")
        // The memory warning, with no dictation running.
        warmth.releaseRequested(ObjectIdentifier(engine))
        // B's tap reads warm or cold now, before the release has run.
        TestSupport.expect(!warmth.isWarm, "B, tapped before the release finished, is recorded warm")
        // The release runs; B then makes a new engine, cold until it prepares.
        warmth.released(ObjectIdentifier(engine))
        let fresh = Engine()
        warmth.made(ObjectIdentifier(fresh))
        TestSupport.expect(!warmth.isWarm, "B's new engine is warm before it prepared")
    }

    /// A release asked for an old engine neither clears nor cools an engine made after it.
    private static func testAnOldReleaseLeavesANewerEngineAlone() {
        var warmth = KeyboardEngineWarmth()
        let old = Engine(), new = Engine()
        warmth.made(ObjectIdentifier(old))
        warmth.prepared(ObjectIdentifier(old))
        warmth.made(ObjectIdentifier(new))
        warmth.prepared(ObjectIdentifier(new))
        warmth.releaseRequested(ObjectIdentifier(old))
        TestSupport.expect(warmth.isWarm, "a release of the old engine cooled the new one")
        TestSupport.expect(!warmth.released(ObjectIdentifier(old)), "a release of the old engine released the new one")
        TestSupport.expectEqual(warmth.engine, ObjectIdentifier(new))
        TestSupport.expect(warmth.isWarm, "a release of the old engine cooled the new one")
        // The old engine's preparation, reported late, changes nothing either.
        warmth.releaseRequested(ObjectIdentifier(new))
        warmth.prepared(ObjectIdentifier(old))
        TestSupport.expect(!warmth.isWarm, "the old engine's late preparation warmed the new one")
    }
}

import DesignCore
import Foundation
import SorelloUI
import Testing

/// ARCHITECTURE.md, sections 3 and 8: the pill reads the voice from a level feed that follows the newest capture
/// only. All audio here is an invented tone.
@Suite struct LevelFeedTests {
    /// `seconds` of a tone at `amplitude`, in 100 ms chunks, the last ending at `start + seconds`.
    static func speak(_ feed: LevelFeed, capture: UInt64, amplitude: Float = 0.3, from start: Double = 0,
                      seconds: Double = 1, chunk: Int = 1_600) {
        let total = Int(seconds * 16_000)
        var sent = 0
        while sent < total {
            let count = min(chunk, total - sent)
            let samples = (0 ..< count).map { amplitude * sinf(Float(sent + $0) * 0.2) }
            sent += count
            feed.heard(samples, at: start + Double(sent) / 16_000, capture: capture)
        }
    }

    @Test func aVoiceRaisesTheLevelAndAnEndingLowersIt() {
        let feed = LevelFeed()
        #expect(feed.level(at: 0) == (0, nil))
        Self.speak(feed, capture: 1)
        let speaking = feed.level(at: 1)
        #expect(speaking.level > 0.8 && speaking.capture == 1)
        feed.captureEnded(capture: 1)
        #expect(feed.level(at: 1) == (0, 1))
    }

    /// The meter's blocks are 100 ms whatever size the chunks arrive in, so the level does not depend on the
    /// capture adapter's buffers.
    @Test func chunkSizeDoesNotChangeTheLevel() {
        var levels: [Double] = []
        for chunk in [160, 341, 1_600, 4_000] {
            let feed = LevelFeed()
            Self.speak(feed, capture: 7, seconds: 1, chunk: chunk)
            Self.speak(feed, capture: 7, amplitude: 0.001, from: 1, seconds: 0.1, chunk: chunk)
            levels.append(feed.level(at: 1.1).level)
        }
        #expect(levels.allSatisfy { abs($0 - levels[0]) < 1e-6 }, "\(levels)")
    }

    /// Once a newer capture has been heard, a chunk from an older one changes nothing: a stopped dictation's last
    /// buffered audio must not disturb the next dictation's wave.
    @Test func anOlderChunkAfterANewerOneIsIgnored() {
        let feed = LevelFeed()
        Self.speak(feed, capture: 1, amplitude: 0.5)
        Self.speak(feed, capture: 2, amplitude: 0.0005, from: 1, seconds: 0.5)
        let quiet = feed.level(at: 1.5)
        #expect(quiet.capture == 2)
        Self.speak(feed, capture: 1, amplitude: 0.5, from: 1.5, seconds: 0.3)
        #expect(feed.level(at: 1.5) == quiet)
    }

    /// An older capture's ending, arriving after a newer capture has been heard, does not flatten the newer wave.
    @Test func anOlderEndingAfterANewerChunkIsIgnored() {
        let feed = LevelFeed()
        Self.speak(feed, capture: 1)
        Self.speak(feed, capture: 2, from: 1)
        let speaking = feed.level(at: 2)
        feed.captureEnded(capture: 1)
        #expect(feed.level(at: 2) == speaking)
        #expect(speaking.level > 0.8)
        // An ending for a capture never heard changes nothing either.
        feed.captureEnded(capture: 3)
        #expect(feed.level(at: 2) == speaking)
    }

    /// A chunk that arrives after its own capture ended does not bring the level back.
    @Test func aLateChunkCannotReviveAnEndedCapture() {
        let feed = LevelFeed()
        Self.speak(feed, capture: 4)
        feed.captureEnded(capture: 4)
        Self.speak(feed, capture: 4, from: 1, seconds: 0.4)
        #expect(feed.level(at: 1.4) == (0, 4))
        // The next capture is heard as usual.
        Self.speak(feed, capture: 5, from: 2)
        #expect(feed.level(at: 3).level > 0.8)
    }

    /// A capture that ended before any of its chunks was heard stays ended: its buffered chunks, arriving late, do
    /// not raise the level, whether or not another capture was heard before it.
    @Test func aCaptureEndedBeforeItsFirstChunkStaysEnded() {
        let fresh = LevelFeed()
        fresh.captureEnded(capture: 4)
        Self.speak(fresh, capture: 4)
        #expect(fresh.level(at: 1).level == 0)
        let after = LevelFeed()
        Self.speak(after, capture: 3)
        after.captureEnded(capture: 3)
        after.captureEnded(capture: 4)
        Self.speak(after, capture: 4, from: 1)
        #expect(after.level(at: 2).level == 0)
        Self.speak(after, capture: 5, from: 2)
        #expect(after.level(at: 3).level > 0.8)
    }

    /// A level not refreshed for half a second reads as silence: a stalled microphone does not freeze the wave.
    @Test func aStalledCaptureFallsToRest() {
        let feed = LevelFeed()
        Self.speak(feed, capture: 1)
        #expect(feed.level(at: 1 + LevelFeed.staleAfter - 0.01).level > 0.8)
        #expect(feed.level(at: 1 + LevelFeed.staleAfter + 0.01).level == 0)
    }

    /// Many threads may hear at once while the pill reads; nothing is lost or torn.
    @Test func itIsSafeAcrossThreads() async {
        let feed = LevelFeed()
        await withTaskGroup(of: Void.self) { group in
            for capture in 1 ... 4 {
                group.addTask { Self.speak(feed, capture: UInt64(capture), seconds: 0.5, chunk: 512) }
            }
            group.addTask {
                for step in 0 ..< 200 { _ = feed.level(at: Double(step) / 100) }
            }
        }
        let final = feed.level(at: 0.5)
        #expect(final.capture == 4)
        #expect(final.level >= 0 && final.level <= 1)
    }
}

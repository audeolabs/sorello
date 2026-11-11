import DesignCore
import Foundation
import Synchronization

/// How loud the voice is now, for the pill's wave (ARCHITECTURE.md, section 8, "Listening"). The audio path hands it
/// every captured chunk with the chunk's time and the number of the capture it belongs to; the pill reads the level
/// once a frame. The app layer adapts the session's `LevelSink` to it, a dictation's id being its capture number.
///
/// It follows the newest capture only. Once a chunk from a capture has been accepted, chunks and endings from any
/// capture with a lower number are ignored, and a capture that has ended stays ended: a stopped dictation keeps
/// delivering its last buffered chunks while the next one has already started, and those must not disturb the new
/// wave. A capture that ended before any of its chunks was heard is remembered too, so its late chunks are ignored.
///
/// Thread-safe. `heard` runs on the audio path, so it only sums squares into a fixed block under a lock, and
/// allocates nothing.
public nonisolated final class LevelFeed: Sendable {
    /// A level not refreshed for this long reads as silence, so a microphone that stalls mid-word does not leave the
    /// wave frozen in a swell.
    public static let staleAfter = 0.5

    private struct State {
        var capture: UInt64?
        var ended = false
        var meter = LevelMeter()
        var sum: Float = 0
        var count = 0
        var level = 0.0
        var refreshed = -Double.infinity
        /// The newest capture reported ended, heard or not: nothing it or an older capture delivers counts.
        var latestEnded: UInt64?
    }

    private let state = Mutex(State())

    public init() {}

    /// Hears `samples` (16 kHz mono) whose last sample was captured at `time`, monotonic seconds on the clock the
    /// overlay was given, during capture number `capture`.
    public func heard(_ samples: [Float], at time: TimeInterval, capture: UInt64) {
        state.withLock { state in
            if let ended = state.latestEnded, capture <= ended { return }
            if let current = state.capture {
                guard capture >= current else { return }
                if capture > current { state = State(capture: capture, latestEnded: state.latestEnded) }
            } else {
                state.capture = capture
            }
            guard !state.ended else { return }
            for sample in samples {
                state.sum += sample * sample
                state.count += 1
                if state.count == LevelMeter.blockSize {
                    state.meter.update(meanSquare: state.sum / Float(state.count), count: state.count)
                    state.sum = 0
                    state.count = 0
                    state.level = Double(state.meter.level)
                    state.refreshed = time
                }
            }
        }
    }

    /// Capture number `capture` ended or was discarded: the level falls to rest if it is the capture being shown, and
    /// nothing it delivers afterwards counts. An ending from a capture older than the one shown is ignored.
    public func captureEnded(capture: UInt64) {
        state.withLock { state in
            if let current = state.capture, capture < current { return }
            state.latestEnded = max(state.latestEnded ?? capture, capture)
            guard state.capture == capture else { return }
            state.ended = true
            state.level = 0
        }
    }

    /// The level now, 0 to 1, and the capture it belongs to (nil before anything was heard). `now` is on the same
    /// clock as the chunks' times.
    public func level(at now: TimeInterval) -> (level: Double, capture: UInt64?) {
        state.withLock { state in
            let fresh = !state.ended && now - state.refreshed <= Self.staleAfter
            return (fresh ? state.level : 0, state.capture)
        }
    }
}

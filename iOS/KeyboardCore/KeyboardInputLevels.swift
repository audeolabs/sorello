#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// The input's loudest and typical level over an in-keyboard recording (ARCHITECTURE.md, "In-keyboard dictation
/// (experiment)", Record): each captured chunk's RMS in whole dBFS, from -120 to 0, counted in a histogram, so it keeps
/// numbers only and never the audio. Pure.
struct KeyboardInputLevels: Equatable, Sendable {
    static let floorDBFS = -120
    /// Chunks per whole dBFS, from `floorDBFS` (index 0) to 0.
    private var counts = [Int](repeating: 0, count: -floorDBFS + 1)
    private var total = 0

    /// One captured chunk. An empty chunk, or one holding a non-finite sample, adds nothing.
    mutating func add(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        guard sumOfSquares.isFinite else { return }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        let dBFS = rms > 0 ? Int((20 * log10f(rms)).rounded()) : Self.floorDBFS
        counts[min(max(dBFS, Self.floorDBFS), 0) - Self.floorDBFS] += 1
        total += 1
    }

    /// The loudest chunk's level; nil before any chunk.
    var loudestDBFS: Int? {
        counts.lastIndex { $0 > 0 }.map { $0 + Self.floorDBFS }
    }

    /// The median chunk's level (the higher middle of an even count); nil before any chunk.
    var typicalDBFS: Int? {
        guard total > 0 else { return nil }
        var seen = 0
        for (index, count) in counts.enumerated() {
            seen += count
            if seen > total / 2 { return index + Self.floorDBFS }
        }
        return nil
    }
}
#endif

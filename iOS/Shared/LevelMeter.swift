import Foundation

/// RMS in dBFS mapped onto the speaker's own range, with a fast attack and a release that still falls between
/// syllables, so the keyboard's wave and the app's level bars follow the voice: it falls in about 0.2 s. A real voice
/// at arm's length often sits at -35 to -25 dBFS, where a fixed window topping out at -12 dBFS leaves a quiet phrase at
/// -32 dBFS flat, so the window runs up to the recording's recent loudest moment, a peak that holds for a moment and
/// then sinks slowly, never below a floor, and down 27 dB from it, never below an absolute noise gate. Soft, normal and
/// loud speakers alike reach the top on their syllables; a quiet room (below the gate) stays at 0, and the floor keeps
/// a murmur just above the gate small.
struct LevelMeter {
    /// Below this the input is the room, not a voice: 0.
    static let gateDB: Float = -45
    /// The peak never sinks below this, so a murmur just above the gate is never stretched to the top.
    static let peakFloorDB: Float = -30
    /// How long the peak holds after the loudest moment, and how fast it then sinks.
    static let peakHold: Float = 1.2
    static let peakDecayDBPerSecond: Float = 6
    /// The window's depth under the peak at most, so a loud speaker's gaps between syllables still read as gaps.
    static let rangeDB: Float = 27
    private static let attackBlend: Float = 0.8
    private static let releaseBlend: Float = 0.55

    private let sampleRate: Float
    private(set) var level: Float = 0
    private var peakDB = Self.peakFloorDB
    private var sincePeak: Float = 0

    init(sampleRate: Double = 16_000) {
        self.sampleRate = Float(sampleRate)
    }

    mutating func update<Samples: Collection>(with samples: Samples) where Samples.Element == Float {
        guard !samples.isEmpty else { return }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms.isFinite else { return }
        let levelDB = 20 * log10f(max(rms, 0.000_01))
        sincePeak += Float(samples.count) / sampleRate
        if sincePeak > Self.peakHold {
            peakDB -= Self.peakDecayDBPerSecond * min(sincePeak - Self.peakHold, Float(samples.count) / sampleRate)
        }
        if levelDB >= peakDB {
            peakDB = levelDB
            sincePeak = 0
        }
        peakDB = max(peakDB, Self.peakFloorDB)
        let low = max(Self.gateDB, peakDB - Self.rangeDB)
        let target = min(max((levelDB - low) / (peakDB - low), 0), 1)
        level += (target - level) * (target > level ? Self.attackBlend : Self.releaseBlend)
    }
}

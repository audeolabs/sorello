import Foundation
@testable import SpeechEngine

/// Invented signals at 16 kHz: tones, seeded noise and zeros. No recorded audio is used anywhere in the tests.
enum Signals {
    static func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

    static func zeros(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: s(seconds)) }

    /// A sine whose RMS is `level` dB relative to full scale.
    static func tone(_ seconds: Double, level: Double, frequency: Double = 440) -> [Float] {
        let amplitude = pow(10, level / 20) * 2.0.squareRoot()
        return (0..<s(seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 16_000)) }
    }

    /// Uniform white noise from a seeded generator, with RMS `level` dB.
    static func noise(_ seconds: Double, level: Double, seed: UInt64) -> [Float] {
        let amplitude = pow(10, level / 20) * 3.0.squareRoot()
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<s(seconds)).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(amplitude * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
        }
    }

    static func add(_ signal: [Float], to input: inout [Float], at start: Int) {
        for (offset, sample) in signal.enumerated() { input[start + offset] += sample }
    }

    /// Feeds `input` to a compactor in reads cycling through `reads` (all at once by default).
    static func compact(_ input: [Float], _ compactor: SilenceCompactor = .init(), reads: [Int] = []) -> [Float] {
        var compactor = compactor, output: [Float] = [], start = 0, index = 0
        repeat {
            let count = reads.isEmpty ? input.count : reads[index % reads.count]
            let end = min(start + count, input.count)
            compactor.append(Array(input[start..<end])) { output += $0 }
            start = end
            index += 1
        } while start < input.count
        compactor.finish { output += $0 }
        return output
    }
}

#if SORELLO_LEGACY
import Foundation
import NativeEncoder
import Testing
@testable import SpeechEngine

/// The projection kernel of Sorello's own encoder against the arithmetic ARCHITECTURE.md, section 15, "The encoder on
/// an Intel Mac", states: each input rounded to 8 bits with one scale per group, multiplied by the ±1 weights exactly,
/// scaled in 32-bit floating point. Every kernel this processor runs must give that result. The inputs are invented,
/// and chosen so that every step of the arithmetic is exact, so any order of summation gives the same float.
struct NativeKernelTests {
    /// A matrix of invented signs and scales, and invented inputs: each group's largest magnitude is exactly
    /// 127 · 2^e, and every input is an integer times 2^e, with one e for each row of inputs.
    struct Case {
        let rows: Int, columns: Int, inputs: Int, group: Int
        let bits: [UInt8], scales: [Float], x: [Float]

        init(rows: Int, columns: Int, inputs: Int, group: Int, seed: UInt64) {
            var generator = SplitMix(seed)
            self.rows = rows; self.columns = columns; self.inputs = inputs; self.group = group
            bits = (0..<(rows * columns / 8)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            // Scales an FP16 value holds exactly: up to ten significant bits.
            scales = (0..<rows).map { _ in Float(generator.next() % 1000 + 1) / 4096 }
            var x = [Float](repeating: 0, count: inputs * columns)
            for m in 0..<inputs {
                let unit = Float(sign: .plus, exponent: Int(generator.next() % 9) - 6, significand: 1)
                for start in stride(from: 0, to: columns, by: group) {
                    for k in start..<start + group {
                        x[m * columns + k] = Float(Int(generator.next() % 255) - 127) * unit
                    }
                    // The group's largest magnitude, at a place of its own; a few groups are all zeros.
                    if generator.next() % 17 == 0 {
                        for k in start..<start + group { x[m * columns + k] = 0 }
                    } else {
                        x[m * columns + start + Int(generator.next() % UInt64(group))] = (generator.next() % 2 == 0 ? 127 : -127) * unit
                    }
                }
            }
            self.x = x
        }

        /// The arithmetic as stated, in the order written.
        func expected() -> [Float] {
            var y = [Float](repeating: 0, count: inputs * rows)
            for m in 0..<inputs {
                for n in 0..<rows {
                    var total: Float = 0
                    for start in stride(from: 0, to: columns, by: group) {
                        let values = x[(m * columns + start)..<(m * columns + start + group)]
                        let amax = values.map(abs).max() ?? 0
                        guard amax > 0 else { continue }
                        let inverse = 127 / amax
                        var dot = 0
                        for (offset, value) in values.enumerated() {
                            let q = Int(max(-127, min(127, (value * inverse).rounded(.toNearestOrEven))))
                            let k = start + offset
                            let bit = (bits[(n * columns + k) / 8] >> ((n * columns + k) % 8)) & 1
                            dot += bit == 1 ? q : -q
                        }
                        total += amax / 127 * Float(dot)
                    }
                    y[m * rows + n] = scales[n] * total
                }
            }
            return y
        }

        /// The FP16 bits of `value`, a normal number whose significand fits in FP16's (Float16 does not exist on an
        /// Intel Mac).
        static func half(_ value: Float) -> UInt16 {
            let bits = value.bitPattern
            let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
            precondition(exponent > 0 && exponent < 31 && bits & 0x1FFF == 0)
            return UInt16((bits >> 16) & 0x8000) | UInt16(exponent) << 10 | UInt16((bits >> 13) & 0x3FF)
        }

        /// What `kernel` gives on this case.
        func run(_ kernel: (UnsafePointer<Float>?, Int32, Int32, OpaquePointer?, UnsafeMutablePointer<Float>?, Int32,
                            OpaquePointer?) -> Void) throws -> [Float] {
            let pool = try #require(kea_pool_create(3))
            defer { kea_pool_destroy(pool) }
            let scaleBits = scales.map(Self.half)
            let matrix = try bits.withUnsafeBufferPointer { b in
                try scaleBits.withUnsafeBufferPointer { s in
                    var w = kea_bits(bits: b.baseAddress, scale_f16: s.baseAddress, N: Int32(rows), K: Int32(columns),
                                     group: Int32(group))
                    return try #require(kea_int8_pack(&w))
                }
            }
            defer { kea_int8_free(matrix) }
            var y = [Float](repeating: .nan, count: inputs * rows)
            x.withUnsafeBufferPointer { xs in
                y.withUnsafeMutableBufferPointer { ys in
                    kernel(xs.baseAddress, Int32(inputs), Int32(columns), matrix, ys.baseAddress, Int32(rows), pool)
                }
            }
            return y
        }
    }

    static let cases: [(columns: Int, group: Int, inputs: Int)] = [
        (1024, 32, 1), (1024, 64, 23), (1024, 128, 188), (4096, 32, 23), (4096, 64, 176), (4096, 128, 1),
    ]

    @Test("The kernel this processor runs gives exactly the stated arithmetic", arguments: cases)
    func theKernelGivesTheStatedArithmetic(columns: Int, group: Int, inputs: Int) throws {
        let invented = Case(rows: 24, columns: columns, inputs: inputs, group: group, seed: UInt64(columns * group + inputs))
        let expected = invented.expected()
        #expect(try invented.run { kea_int8_proj($0, $1, $2, $3, $4, $5, $6) } == expected)
    }

    @Test("The portable kernel, which every processor has, gives the same", arguments: cases)
    func thePortableKernelGivesTheSame(columns: Int, group: Int, inputs: Int) throws {
        let invented = Case(rows: 24, columns: columns, inputs: inputs, group: group, seed: UInt64(columns * group + inputs))
        #expect(try invented.run { kea_int8_proj_portable($0, $1, $2, $3, $4, $5, $6) } == invented.expected())
    }

    @Test func aShapeTheKernelCannotRunIsRefused() {
        let bits = [UInt8](repeating: 0, count: 64), scales = [UInt16](repeating: 0x3C00, count: 8)
        bits.withUnsafeBufferPointer { b in
            scales.withUnsafeBufferPointer { s in
                for (columns, group) in [(64, 48), (96, 32), (8192, 64)] {
                    var w = kea_bits(bits: b.baseAddress, scale_f16: s.baseAddress, N: 8, K: Int32(columns), group: Int32(group))
                    #expect(kea_int8_pack(&w) == nil, "\(columns) inputs in groups of \(group)")
                }
            }
        }
    }
}

/// The decoder that runs with Sorello's own encoder holds its matrices as 8-bit integers, one scale per row of each
/// (ARCHITECTURE.md, section 15). On invented weights that 8 bits per row hold exactly, it computes what the 32-bit
/// decoder computes, to within the rounding of 32-bit sums taken in another order.
struct NativeDecoderTests {
    /// Invented decoder weights: every row of the matrices the native decoder keeps in 8 bits is a power of two times
    /// integers of at most 127, with 127 among them; the rest are any small values.
    static func weights(seed: UInt64) throws -> NativeWeights {
        var generator = SplitMix(seed)
        func small() -> Float { Float(Int(generator.next() % 2001) - 1000) / 4000 }
        func exact(_ rows: Int, _ columns: Int) -> [Float] {
            (0..<rows).flatMap { _ -> [Float] in
                let unit = Float(sign: .plus, exponent: -Int(generator.next() % 4) - 7, significand: 1)
                var row = (0..<columns).map { _ in Float(Int(generator.next() % 255) - 127) * unit }
                row[Int(generator.next() % UInt64(columns))] = 127 * unit
                return row
            }
        }
        let h = NativeWeights.hidden, g = 4 * h, p = "decoder.prediction."
        var embed = (0..<(NativeWeights.vocabPlusBlank * h)).map { _ in small() }
        for i in (NativeWeights.vocabPlusBlank - 1) * h..<NativeWeights.vocabPlusBlank * h { embed[i] = 0 }
        let tensors: [String: [Float]] = [
            p + "embed.weight": embed,
            p + "dec_rnn.lstm.weight_ih_l0": (0..<(g * h)).map { _ in small() / 8 },
            p + "dec_rnn.lstm.weight_hh_l0": exact(g, h),
            p + "dec_rnn.lstm.bias_ih_l0": (0..<g).map { _ in small() }, p + "dec_rnn.lstm.bias_hh_l0": (0..<g).map { _ in small() },
            p + "dec_rnn.lstm.weight_ih_l1": exact(g, h), p + "dec_rnn.lstm.weight_hh_l1": exact(g, h),
            p + "dec_rnn.lstm.bias_ih_l1": (0..<g).map { _ in small() }, p + "dec_rnn.lstm.bias_hh_l1": (0..<g).map { _ in small() },
            "joint.enc.weight": (0..<(h * NativeWeights.dModel)).map { _ in small() / 8 }, "joint.enc.bias": (0..<h).map { _ in small() },
            "joint.pred.weight": exact(h, h), "joint.pred.bias": (0..<h).map { _ in small() },
            "joint.joint_net.2.weight": exact(NativeWeights.outputs, h),
            "joint.joint_net.2.bias": (0..<NativeWeights.outputs).map { _ in small() },
        ]
        return try NativeWeights(tensors: tensors)
    }

    static func close(_ a: [Float], _ b: [Float]) -> Bool {
        let scale = max(b.map(abs).max() ?? 0, 1e-6)
        return zip(a, b).allSatisfy { abs($0 - $1) <= 2e-5 * scale }
    }

    @Test func itComputesWhatTheFullPrecisionDecoderComputes() throws {
        let math = NativeMath(try Self.weights(seed: 7))
        let decoder = try #require(NativeDecoder(math))
        let hidden = NativeWeights.hidden
        var h32 = [Float](repeating: 0, count: 2 * hidden), c32 = h32, h8 = h32, c8 = h32
        var g32 = [Float](repeating: 0, count: hidden), g8 = g32, z = g32
        var logits32 = [Float](repeating: 0, count: NativeWeights.outputs), logits8 = logits32
        var generator = SplitMix(11)
        let f = (0..<hidden).map { _ in Float(Int(generator.next() % 2001) - 1000) / 500 }
        // The start symbol, then invented tokens, each followed by the joint, as decoding does.
        for token in [1024, 17, 3, 940, 512, 1023] {
            math.predict(token, h: &h32, c: &c32, g: &g32)
            decoder.predict(token, h: &h8, c: &c8, g: &g8)
            #expect(Self.close(h8, h32) && Self.close(c8, c32) && Self.close(g8, g32), "after token \(token)")
            let full = math.joint(f: f, g: &g32, z: &z, logits: &logits32)
            let native = decoder.joint(f: f, g: g8, logits: &logits8)
            #expect(Self.close(logits8, logits32), "joint after token \(token)")
            #expect(native == full, "the same token and duration after token \(token)")
        }
    }
}

/// A small deterministic generator, so a failure can be reproduced.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49EB_133D_D3E4
        return z ^ (z >> 31)
    }
}
#endif

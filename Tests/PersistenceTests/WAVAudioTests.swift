import Foundation
import Persistence
import Testing

/// The Run Log's audio format: exactly 16 kHz mono 16-bit PCM WAV. The samples are synthetic.
@Suite struct WAVAudioTests {
    /// Little-endian bytes of `values`, for building a fixture by hand.
    private func bytes(_ values: [any FixedWidthInteger]) -> [UInt8] {
        values.flatMap { value -> [UInt8] in
            let width = value.bitWidth / 8
            let bits = UInt64(truncatingIfNeeded: value)
            return (0..<width).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) }
        }
    }

    private func header(dataSize: UInt32, channels: UInt16 = 1, rate: UInt32 = 16_000, bits: UInt16 = 16,
                        format: UInt16 = 1) -> [UInt8] {
        let frame = channels * bits / 8
        return Array("RIFF".utf8) + bytes([UInt32(36) + dataSize]) + Array("WAVEfmt ".utf8)
            + bytes([UInt32(16), format, channels, rate, rate * UInt32(frame), frame, bits])
            + Array("data".utf8) + bytes([dataSize])
    }

    @Test func encodesTheExactBytes() {
        let encoded = WAVAudio.encode([0, 1, -1, 0.5, -0.25])
        let expected = header(dataSize: 10) + bytes([Int16(0), Int16(32_767), Int16(-32_767), Int16(16_384),
                                                    Int16(-8_192)])
        #expect([UInt8](encoded) == expected)
    }

    @Test func emptyRecordingIsAHeaderOnly() throws {
        let encoded = WAVAudio.encode([])
        #expect([UInt8](encoded) == header(dataSize: 0))
        #expect(try WAVAudio.decode(encoded) == [])
    }

    @Test func readsTheHandBuiltFixture() throws {
        let fixture = Data(header(dataSize: 6) + bytes([Int16(32_767), Int16(-32_768), Int16(0)]))
        #expect(try WAVAudio.decode(fixture) == [1, -1, 0])
    }

    @Test func roundTripIsWithinHalfAStep() throws {
        let samples = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.8) }
        let decoded = try WAVAudio.decode(WAVAudio.encode(samples))
        #expect(decoded.count == samples.count)
        let worst = zip(samples, decoded).map { abs($0 - $1) }.max() ?? 0
        #expect(worst <= 0.5 / 32_767 + 1e-7)
    }

    @Test func clampsWhatIsOutOfRange() throws {
        let decoded = try WAVAudio.decode(WAVAudio.encode([2, -3, .infinity, -.infinity, .nan]))
        #expect(decoded == [1, -1, 1, -1, 0])
    }

    @Test func skipsChunksItDoesNotUse() throws {
        var fixture = header(dataSize: 2) + bytes([Int16(32_767)])
        // A 3-byte LIST chunk with its pad byte, between the format and the data.
        let list = Array("LIST".utf8) + bytes([UInt32(3)]) + [1, 2, 3, 0]
        fixture.insert(contentsOf: list, at: 36)
        fixture.replaceSubrange(4..<8, with: bytes([UInt32(fixture.count - 8)]))
        #expect(try WAVAudio.decode(Data(fixture)) == [1])
    }

    @Test func refusesAnythingElse() {
        #expect(throws: WAVAudioError.notWAV) { try WAVAudio.decode(Data("not audio".utf8)) }
        #expect(throws: WAVAudioError.notWAV) { try WAVAudio.decode(Data()) }
        #expect(throws: WAVAudioError.unsupportedFormat) {
            try WAVAudio.decode(Data(header(dataSize: 4, channels: 2) + [0, 0, 0, 0]))
        }
        #expect(throws: WAVAudioError.unsupportedFormat) {
            try WAVAudio.decode(Data(header(dataSize: 2, rate: 44_100) + [0, 0]))
        }
        #expect(throws: WAVAudioError.unsupportedFormat) {
            try WAVAudio.decode(Data(header(dataSize: 2, bits: 8) + [0, 0]))
        }
        #expect(throws: WAVAudioError.unsupportedFormat) {
            try WAVAudio.decode(Data(header(dataSize: 2, format: 3) + [0, 0]))
        }
    }

    @Test func refusesATruncatedFile() {
        let whole = WAVAudio.encode([0.1, 0.2, 0.3])
        #expect(throws: WAVAudioError.truncated) { try WAVAudio.decode(whole.dropLast(1)) }
        #expect(throws: WAVAudioError.truncated) { try WAVAudio.decode(whole.prefix(40)) }
        #expect(throws: WAVAudioError.truncated) { try WAVAudio.decode(Data(header(dataSize: 3) + [0, 0, 0])) }
    }
}

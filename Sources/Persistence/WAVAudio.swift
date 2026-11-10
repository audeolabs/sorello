import Foundation

/// The Run Log's audio format, and only that: 16 kHz mono 16-bit PCM in a RIFF WAVE file. Every recording crosses
/// the ports as 16 kHz mono `Float`, so nothing else is ever written, and reading accepts only what this writes
/// (plus chunks it does not use, which it skips).
public enum WAVAudio {
    public static let sampleRate = 16_000
    private static let headerSize = 44

    /// The bytes of a WAV file holding `samples`. Samples are clamped to -1...1 and rounded to the nearest 16-bit
    /// step, so a file read back differs from the input by at most half a step (1/65534).
    public static func encode(_ samples: [Float]) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: headerSize + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(clamping: 36 + dataSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data) // PCM
        append(UInt16(1), to: &data) // mono
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data) // bytes per second
        append(UInt16(2), to: &data) // bytes per frame
        append(UInt16(16), to: &data) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(clamping: dataSize), to: &data)
        let start = data.count
        data.count += dataSize
        data.withUnsafeMutableBytes { buffer in
            for (index, sample) in samples.enumerated() {
                let clamped = sample.isNaN ? 0 : min(max(sample, -1), 1)
                let value = Int16((clamped * 32_767).rounded())
                buffer.storeBytes(of: value.littleEndian, toByteOffset: start + index * 2, as: Int16.self)
            }
        }
        return data
    }

    /// The samples in a WAV file in exactly the format `encode` writes, as `Float` in -1...1.
    public static func decode(_ data: Data) throws(WAVAudioError) -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8)
        else { throw .notWAV }
        var offset = 12
        var sawFormat = false
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4]
            let size = Int(readUInt32(bytes, at: offset + 4))
            let body = offset + 8
            guard size <= bytes.count - body else { throw .truncated }
            if id.elementsEqual("fmt ".utf8) {
                guard size >= 16, readUInt16(bytes, at: body) == 1, readUInt16(bytes, at: body + 2) == 1,
                      readUInt32(bytes, at: body + 4) == UInt32(sampleRate), readUInt16(bytes, at: body + 12) == 2,
                      readUInt16(bytes, at: body + 14) == 16 else { throw .unsupportedFormat }
                sawFormat = true
            } else if id.elementsEqual("data".utf8) {
                guard sawFormat else { throw .unsupportedFormat }
                guard size.isMultiple(of: 2) else { throw .truncated }
                return stride(from: body, to: body + size, by: 2).map { position in
                    let value = Int16(bitPattern: readUInt16(bytes, at: position))
                    return max(Float(value) / 32_767, -1)
                }
            }
            // Chunks are padded to an even length.
            offset = body + size + (size & 1)
        }
        throw sawFormat ? .truncated : .unsupportedFormat
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

/// Why WAV bytes could not be read.
public enum WAVAudioError: Error, Sendable, Equatable {
    /// Not a RIFF WAVE file.
    case notWAV
    /// A WAVE file in another format: not 16 kHz, not mono, not 16-bit PCM, or without a format chunk.
    case unsupportedFormat
    /// The file ends before its audio does.
    case truncated
}

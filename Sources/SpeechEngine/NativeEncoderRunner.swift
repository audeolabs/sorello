#if SORELLO_LEGACY
import Foundation
import NativeEncoder

/// Sorello's own encoder, run on the processor (ARCHITECTURE.md, section 15, "The encoder on an Intel Mac"). It reads
/// the build's `Encoder.mlmodelc/model.mil` and `weights/weight.bin`, which the engine has already checked, and keeps
/// the weight file mapped while it lives. Used only on the engine's executor.
final class NativeEncoderRunner {
    private let encoder: OpaquePointer
    /// The weight file, mapped; the encoder reads its packed weights from here.
    private let weights: Data

    /// The encoder for the build at `directory`, on `threads` threads. Throws `invalidModelFile` if the build's
    /// program does not hold the weights the encoder needs, with the sizes it needs.
    init(directory: URL, threads: Int) throws(TranscriptionError) {
        let encoderDirectory = directory.appendingPathComponent("Encoder.mlmodelc")
        guard let program = try? String(contentsOf: encoderDirectory.appendingPathComponent("model.mil"), encoding: .utf8),
              let weights = try? Data(contentsOf: encoderDirectory.appendingPathComponent("weights/weight.bin"),
                                      options: .alwaysMapped) else {
            throw .invalidModelFile
        }
        let index = try weights.withUnsafeBytes { bytes throws(TranscriptionError) in
            try EncoderProgram(program: program, weightFile: bytes).index
        }
        let opened: OpaquePointer? = weights.withUnsafeBytes { bytes in
            index.utf8CString.withUnsafeBufferPointer { text in
                kea_open(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, text.baseAddress,
                         text.count - 1, Int32(threads))
            }
        }
        guard let opened else { throw .invalidModelFile }
        encoder = opened
        self.weights = weights
    }

    deinit { kea_close(encoder) }

    /// One processor thread for each core, as the system counts them.
    static var threadsForThisMac: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 else {
            return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        }
        return Int(cores)
    }

    /// The projection kernel this processor runs, for the verification tools.
    var kernel: String { kea_int8_uses_avx2() != 0 ? "int8, AVX2" : "int8, portable" }

    /// The encoder's output for features `[128, stride]`, feature-major, of which the first `valid` frames are the
    /// audio: time-major frames of 1024 values, only as many as the audio fills.
    func encode(features: [Float], stride: Int, valid: Int) throws(TranscriptionError) -> (values: FloatBuffer, frames: Int) {
        guard features.count == 128 * stride, valid > 0, valid <= stride else { throw .invalidAudio }
        let output = FloatBuffer(count: Self.maximumFrames * 1024)
        var frames: Int32 = 0
        let status = features.withUnsafeBufferPointer { mel in
            kea_encode(encoder, mel.baseAddress, Int32(stride), Int32(valid), output.pointer, &frames)
        }
        guard status == 0, frames > 0, Int(frames) <= Self.maximumFrames else { throw .invalidModelOutput }
        return (output, Int(frames))
    }

    /// The frames of a full 15 s chunk.
    static let maximumFrames = 188
}

/// The decoder's step for Sorello's own encoder: `NativeMath`'s prediction network and joint with their matrices held
/// as 8-bit integers, one scale per row of each, multiplied by 32-bit inputs (ARCHITECTURE.md, section 15).
final class NativeDecoder {
    private let decoder: OpaquePointer

    /// The decoder for `math`'s weights; nil if it cannot be made.
    init?(_ math: NativeMath) {
        let w = math.w
        guard let opened = kea_decoder_open(math.table0, w.whh0, w.w1cat, w.bias1, w.predW, w.predB, w.outW, w.outB)
        else { return nil }
        decoder = opened
    }

    deinit { kea_decoder_close(decoder) }

    /// As `NativeMath.predict`.
    func predict(_ token: Int, h: UnsafeMutablePointer<Float>, c: UnsafeMutablePointer<Float>,
                 g: UnsafeMutablePointer<Float>) {
        kea_decoder_predict(decoder, Int32(token), h, c, g)
    }

    /// As `NativeMath.joint`: writes the logits and returns the first-maximum token over 1025 and duration over 5.
    func joint(f: UnsafePointer<Float>, g: UnsafePointer<Float>, logits: UnsafeMutablePointer<Float>) -> (Int, Int) {
        kea_decoder_joint(decoder, f, g, logits)
        return (Self.argmax(logits, 1025), Self.argmax(logits + 1025, 5))
    }

    private static func argmax(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        var best = 0
        for i in 1..<n where p[i] > p[best] { best = i }
        return best
    }
}

extension EncoderFrames {
    /// Time-major frames the native encoder wrote, `count` of them.
    init(native values: FloatBuffer, count: Int) {
        self.count = count
        hiddenStride = 1
        timeStride = 1024
        base = values.pointer
        owner = values
    }
}
#endif

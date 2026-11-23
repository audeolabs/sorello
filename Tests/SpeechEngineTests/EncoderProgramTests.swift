#if SORELLO_LEGACY
import Foundation
import Testing
@testable import SpeechEngine

/// Reading where an encoder program's weights are (ARCHITECTURE.md, section 15, "The encoder on an Intel Mac"). The
/// program and its weight file are invented here, in the syntax and layout Core ML's tools write.
struct EncoderProgramTests {
    /// A weight file: a 64-byte header for each entry at `header`, saying the values are `bytes` long at `data`.
    static func weightFile(size: Int, entries: [(header: Int, code: UInt32, bytes: UInt64, data: UInt64)],
                           sentinel: UInt32 = 0xDEAD_BEEF) -> [UInt8] {
        var file = [UInt8](repeating: 0, count: size)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        for entry in entries {
            put(sentinel, at: entry.header)
            put(entry.code, at: entry.header + 4)
            put(entry.bytes, at: entry.header + 8)
            put(entry.data, at: entry.header + 16)
        }
        return file
    }

    static func blob(_ offset: Int) -> String {
        "BLOBFILE(path = tensor<string, []>(\"@model_path/weights/weight.bin\"), offset = tensor<uint64, []>(\(offset)))"
    }

    static func scale(_ name: String, at header: Int) -> String {
        "            tensor<fp16, [4]> \(name) = const()[name = tensor<string, []>(\"\(name)\"), val = tensor<fp16, [4]>(\(blob(header)))];"
    }

    static func matrix(_ name: String, at header: Int, table: String = "[-0x1p+0, 0x1p+0]") -> String {
        "            tensor<fp16, [4, 4]> \(name) = constexpr_lut_to_dense()[indices = tensor<uint8, [2]>(\(blob(header))), lut = tensor<fp16, [2]>(\(table)), name = tensor<string, []>(\"\(name)\"), shape = tensor<uint32, [2]>([4, 4])];"
    }

    /// A program with an FP16 scale, a 1-bit matrix and lines that load nothing from the file.
    static let program = [
        "program(1.0)",
        "{",
        "    func main<ios16>(tensor<fp32, [1, 128, 1501]> mel, tensor<int32, [1]> mel_length) {",
        "            tensor<int32, [3]> perm = const()[name = tensor<string, []>(\"perm\"), val = tensor<int32, [3]>([0, 2, 1])];",
        scale("s_scaled_y_0", at: 64),
        matrix("w_weight", at: 192),
        "            tensor<fp16, [1, 4]> y = linear(weight = w_weight, x = x)[name = tensor<string, []>(\"y\")];",
        "    } -> (encoder, encoder_length);",
        "}",
    ].joined(separator: "\n")

    static let goodFile = weightFile(size: 320, entries: [(64, 1, 8, 128), (192, 3, 2, 256)])

    func read(_ program: String = program, _ file: [UInt8] = goodFile) throws -> EncoderProgram {
        try file.withUnsafeBytes { bytes in try EncoderProgram(program: program, weightFile: bytes) }
    }

    @Test func itFindsEveryWeightThatTheProgramLoadsFromItsFile() throws {
        let program = try read()
        #expect(program.weights == [
            "s_scaled_y_0": .init(kind: .fp16, offset: 128, bytes: 8),
            "w_weight": .init(kind: .bits, offset: 256, bytes: 2),
        ])
        #expect(program.index == "s_scaled_y_0 128 8\nw_weight 256 2\n")
    }

    @Test func aProgramThatLoadsNothingHasNoWeights() throws {
        #expect(try read("program(1.0)\n{\n}\n").weights.isEmpty)
    }

    @Test("A header that is not one, a wrong kind, or values outside the file are refused")
    func itRefusesWhatDoesNotFit() {
        let refused: [(String, [UInt8])] = [
            ("not a header", Self.weightFile(size: 320, entries: [(64, 1, 8, 128), (192, 3, 2, 256)], sentinel: 7)),
            ("an FP16 constant whose values are bytes", Self.weightFile(size: 320, entries: [(64, 3, 8, 128), (192, 3, 2, 256)])),
            ("a matrix whose indices are FP16", Self.weightFile(size: 320, entries: [(64, 1, 8, 128), (192, 1, 2, 256)])),
            ("values that run past the end", Self.weightFile(size: 320, entries: [(64, 1, 8, 128), (192, 3, 65, 256)])),
            ("values that start past the end", Self.weightFile(size: 320, entries: [(64, 1, 8, 128), (192, 3, 2, 400)])),
            ("no values", Self.weightFile(size: 320, entries: [(64, 1, 0, 128), (192, 3, 2, 256)])),
        ]
        for (why, file) in refused {
            #expect(throws: TranscriptionError.invalidModelFile, "\(why)") { try read(Self.program, file) }
        }
    }

    @Test func aHeaderPastTheEndOfTheFileIsRefused() {
        let program = Self.program.replacingOccurrences(of: "tensor<uint64, []>(192)", with: "tensor<uint64, []>(300)")
        #expect(throws: TranscriptionError.invalidModelFile) { try read(program) }
    }

    @Test("A 1-bit matrix must look its signs up in {-1, +1}, or the program is not one this encoder runs")
    func aDifferentTableIsRefused() {
        let program = Self.program.replacingOccurrences(of: "[-0x1p+0, 0x1p+0]", with: "[0x1p+0, -0x1p+0]")
        #expect(throws: TranscriptionError.invalidModelFile) { try read(program) }
    }

    @Test func aWeightDefinedTwiceIsRefused() {
        let program = Self.program + "\n" + Self.scale("s_scaled_y_0", at: 64)
        #expect(throws: TranscriptionError.invalidModelFile) { try read(program) }
    }
}
#endif

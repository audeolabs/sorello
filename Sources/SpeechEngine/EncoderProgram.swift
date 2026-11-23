#if SORELLO_LEGACY
import Foundation

/// Where an encoder program's weights are, read from the program's text (`model.mil`) and its weight file
/// (`weights/weight.bin`), for Sorello's own encoder (ARCHITECTURE.md, section 15, "The encoder on an Intel Mac").
///
/// Each constant the program loads from the weight file is a line that names it and gives the offset of a 64-byte
/// header in the file; the header gives where the values are and how many bytes they take. Two kinds are read: FP16
/// constants, and 1-bit matrices, which the program writes as a lookup into the table {-1, +1} of packed indices.
/// Anything else in the program is left alone. A header that is not one, a kind or table other than these, or
/// values outside the file make the program unreadable.
struct EncoderProgram: Equatable {
    struct Weight: Equatable {
        enum Kind: Equatable { case fp16, bits }
        let kind: Kind
        /// Where the values start in the weight file, and how many bytes they take.
        let offset: Int
        let bytes: Int
    }

    let weights: [String: Weight]

    /// The program's weights. Throws `invalidModelFile` if the program cannot be read as described above.
    init(program: String, weightFile: UnsafeRawBufferPointer) throws(TranscriptionError) {
        var weights: [String: Weight] = [:]
        for line in program.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let blob = line.range(of: Self.blobMarker) else { continue }
            let kind: Weight.Kind
            if line.contains("= constexpr_lut_to_dense()") {
                guard line.contains(Self.signTable), line.contains("indices = tensor<uint8, [") else {
                    throw .invalidModelFile
                }
                kind = .bits
            } else if line.contains("= const()") {
                guard line.drop(while: { $0 == " " }).hasPrefix(Self.fp16Prefix) else { continue }
                kind = .fp16
            } else {
                continue
            }
            guard let name = Self.definedName(line), weights[name] == nil,
                  let header = Self.number(after: blob.upperBound, in: line) else {
                throw .invalidModelFile
            }
            weights[name] = try Self.read(header: header, kind: kind, in: weightFile)
        }
        self.weights = weights
    }

    /// What `NativeEncoder` reads: one weight a line, "<name> <offset> <bytes>", sorted by name.
    var index: String {
        weights.keys.sorted().map { "\($0) \(weights[$0]!.offset) \(weights[$0]!.bytes)\n" }.joined()
    }

    private static let blobMarker = "BLOBFILE(path = tensor<string, []>(\"@model_path/weights/weight.bin\"), offset = tensor<uint64, []>("
    private static let signTable = "lut = tensor<fp16, [2]>([-0x1p+0, 0x1p+0])"
    private static let fp16Prefix = "tensor<fp16, ["
    /// The header's sentinel and the weight file's codes for the two kinds of values.
    private static let sentinel: UInt32 = 0xDEAD_BEEF
    private static let fp16Code: UInt32 = 1, uint8Code: UInt32 = 3

    /// The variable a line defines: the word before " = ".
    private static func definedName(_ line: Substring) -> String? {
        guard let equals = line.range(of: " = ") else { return nil }
        let name = line[..<equals.lowerBound].split(separator: " ").last.map(String.init)
        guard let name, !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return name
    }

    /// The decimal number at `index`, up to the closing parenthesis.
    private static func number(after index: Substring.Index, in line: Substring) -> Int? {
        let digits = line[index...].prefix(while: \.isNumber)
        guard !digits.isEmpty, line[digits.endIndex...].hasPrefix(")") else { return nil }
        return Int(digits)
    }

    private static func read(header: Int, kind: Weight.Kind,
                             in file: UnsafeRawBufferPointer) throws(TranscriptionError) -> Weight {
        guard header >= 0, header <= file.count - 64 else { throw .invalidModelFile }
        let sentinel = file.loadUnaligned(fromByteOffset: header, as: UInt32.self)
        let code = file.loadUnaligned(fromByteOffset: header + 4, as: UInt32.self)
        let bytes = file.loadUnaligned(fromByteOffset: header + 8, as: UInt64.self)
        let offset = file.loadUnaligned(fromByteOffset: header + 16, as: UInt64.self)
        // Every Mac is little-endian, as the file is.
        guard sentinel == Self.sentinel, code == (kind == .fp16 ? Self.fp16Code : Self.uint8Code),
              bytes > 0, offset <= UInt64(file.count), bytes <= UInt64(file.count) - offset else {
            throw .invalidModelFile
        }
        return Weight(kind: kind, offset: Int(offset), bytes: Int(bytes))
    }
}
#endif

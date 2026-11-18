import CryptoKit
import Foundation

/// A recovery code (ARCHITECTURE.md, "Notes", Recovery code): 160 random bits, shown as 32 Crockford base32
/// symbols in eight groups of four, which wraps the vault secret into one sealed file.
struct NoteRecoveryCode: Equatable {
    static let byteCount = 20
    static let symbolCount = 32
    /// Crockford's base32 alphabet, without I, L, O and U. Part of the stored format, as the labels below.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let wrapInfo = Data("Sorello notes recovery 1".utf8)
    private static let saltByteCount = 16

    /// The code's bits.
    let bits: Data

    /// A new code from the system's generator.
    static func make() -> NoteRecoveryCode {
        var generator = SystemRandomNumberGenerator()
        return NoteRecoveryCode(bits: Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private init(bits: Data) {
        self.bits = bits
    }

    /// The code `text` spells, or nil: letters in either case, spaces and dashes ignored, O read as 0 and I and L
    /// as 1, and exactly 32 symbols.
    init?(_ text: String) {
        var value: [UInt8] = []
        for character in text.uppercased() {
            switch character {
            case " ", "-", "\t", "\n": continue
            case "O": value.append(0)
            case "I", "L": value.append(1)
            default:
                guard let index = Self.alphabet.firstIndex(of: character) else { return nil }
                value.append(UInt8(index))
            }
        }
        guard value.count == Self.symbolCount else { return nil }
        var bytes = Data()
        var buffer = 0
        var bufferedBits = 0
        for symbol in value {
            buffer = (buffer << 5 | Int(symbol)) & 0xFFFF   // more than the unread bits, never overflowing
            bufferedBits += 5
            if bufferedBits >= 8 {
                bufferedBits -= 8
                bytes.append(UInt8((buffer >> bufferedBits) & 0xFF))
            }
        }
        self.bits = bytes
    }

    /// The code as it is shown: `XXXX-XXXX-…`, eight groups of four symbols. Not `description`, so that the code
    /// never lands in a string by interpolation.
    var displayText: String {
        var symbols: [Character] = []
        var buffer = 0
        var bufferedBits = 0
        for byte in bits {
            buffer = (buffer << 8 | Int(byte)) & 0xFFFF
            bufferedBits += 8
            while bufferedBits >= 5 {
                bufferedBits -= 5
                symbols.append(Self.alphabet[(buffer >> bufferedBits) & 0x1F])
            }
        }
        return stride(from: 0, to: symbols.count, by: 4)
            .map { String(symbols[$0 ..< min($0 + 4, symbols.count)]) }
            .joined(separator: "-")
    }

    /// `secret` sealed under a key derived from this code and a new salt.
    func wrap(_ secret: Data) throws -> Data {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return try NoteSealing.record(secret, as: .recoveryWrap, key: key(salt: salt), keyMaterial: salt)
    }

    /// The secret in `wrap` if this code opens it; nil otherwise.
    func unwrap(_ wrap: Data) -> Data? {
        guard let parts = NoteSealing.parse(wrap, kind: .recoveryWrap), parts.keyMaterial.count == Self.saltByteCount
        else { return nil }
        return NoteSealing.openBox(parts.box, key: key(salt: parts.keyMaterial), identity: .recoveryWrap)
    }

    private func key(salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bits), salt: salt, info: Self.wrapInfo,
                               outputByteCount: 32)
    }
}

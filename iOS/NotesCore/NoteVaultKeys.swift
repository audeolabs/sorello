import CryptoKit
import Foundation

/// The vault secret and the key pair derived from it (ARCHITECTURE.md, "Notes", Secret and keys).
enum NoteVaultKeys {
    static let secretByteCount = 32
    /// Labels of the derivation. Part of the stored format: a different label derives a different key pair, and
    /// no stored note would open.
    private static let salt = Data("Sorello notes vault".utf8)
    private static let info = Data("X25519 key pair 1".utf8)

    /// A new secret: 32 random bytes from the system's generator.
    static func makeSecret() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The private key `secret` derives, or nil if `secret` is not a vault secret.
    static func privateKey(for secret: Data) -> Curve25519.KeyAgreement.PrivateKey? {
        guard secret.count == secretByteCount else { return nil }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info,
                                             outputByteCount: 32)
        return derived.withUnsafeBytes { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data($0)) }
    }

    /// The public key stored as `data`, or nil if it is not one.
    static func publicKey(_ data: Data) -> Curve25519.KeyAgreement.PublicKey? {
        try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }
}

import CryptoKit
import Foundation

/// What a record is. Part of the stored format (ARCHITECTURE.md, "Notes", Sealing).
enum NoteRecordKind: UInt8 {
    case body = 1
    case runStart = 2
    case segment = 3
    case recoveryWrap = 4
}

/// What a record is bound to: the note, the kind, the run (none for a body) and the sequence number. It is never
/// stored in the record; the reader takes it from where the record lies, so a record opens only where it was put.
struct NoteRecordIdentity: Equatable {
    var noteID: UUID
    var kind: NoteRecordKind
    var runID: UUID?
    var sequence: UInt32

    static func body(_ noteID: UUID) -> NoteRecordIdentity {
        NoteRecordIdentity(noteID: noteID, kind: .body, runID: nil, sequence: 0)
    }

    static func runStart(_ noteID: UUID, run runID: UUID) -> NoteRecordIdentity {
        NoteRecordIdentity(noteID: noteID, kind: .runStart, runID: runID, sequence: 0)
    }

    static func segment(_ noteID: UUID, run runID: UUID, sequence: UInt32) -> NoteRecordIdentity {
        NoteRecordIdentity(noteID: noteID, kind: .segment, runID: runID, sequence: sequence)
    }

    static let recoveryWrap = NoteRecordIdentity(noteID: NoteSealing.zeroID, kind: .recoveryWrap, runID: nil, sequence: 0)
}

/// Sealing and opening records (ARCHITECTURE.md, "Notes", Sealing): a header (magic, version, kind), key material
/// and a ChaChaPoly box whose associated data binds the record's identity. Bodies and runs are sealed to the
/// vault's public key through HPKE; only the private key opens them.
enum NoteSealing {
    /// Part of the stored format, as every constant here.
    static let magic = Data("SRNT".utf8)
    static let version: UInt8 = 1
    static let ciphersuite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    private static let hpkeInfo = Data("Sorello notes record 1".utf8)
    private static let contentKeyContext = Data("content key".utf8)
    static let zeroID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Seals `plaintext` as `identity` to `publicKey`, with an encapsulation of its own.
    static func seal(_ plaintext: Data, as identity: NoteRecordIdentity,
                     to publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        try NoteRunSealer(publicKey: publicKey).seal(plaintext, as: identity)
    }

    /// The plaintext of `record` if it opens as `identity` with `privateKey`; nil otherwise.
    static func open(_ record: Data, as identity: NoteRecordIdentity,
                     with privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard identity.kind != .recoveryWrap, let parts = parse(record, kind: identity.kind),
              let recipient = try? HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite, info: hpkeInfo,
                                                  encapsulatedKey: parts.keyMaterial),
              let key = try? recipient.exportSecret(context: contentKeyContext, outputByteCount: 32)
        else { return nil }
        return openBox(parts.box, key: key, identity: identity)
    }

    /// The content key and encapsulated key of a new HPKE context to `publicKey`.
    static func makeContentKey(to publicKey: Curve25519.KeyAgreement.PublicKey) throws
        -> (key: SymmetricKey, encapsulatedKey: Data) {
        let sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: ciphersuite, info: hpkeInfo)
        return (try sender.exportSecret(context: contentKeyContext, outputByteCount: 32), sender.encapsulatedKey)
    }

    /// A record of `identity`'s kind: the header, `keyMaterial` and `plaintext` sealed under `key`.
    static func record(_ plaintext: Data, as identity: NoteRecordIdentity, key: SymmetricKey,
                       keyMaterial: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData(identity)).combined
        var record = header(identity.kind)
        record.append(UInt8(keyMaterial.count >> 8))
        record.append(UInt8(keyMaterial.count & 0xFF))
        record.append(keyMaterial)
        record.append(box)
        return record
    }

    /// The key material and the box of `record` if it is a record of `kind`.
    static func parse(_ record: Data, kind: NoteRecordKind) -> (keyMaterial: Data, box: Data)? {
        let bytes = [UInt8](record)
        let headerLength = magic.count + 2
        guard bytes.count >= headerLength + 2, Data(bytes[0 ..< headerLength]) == header(kind) else { return nil }
        let length = Int(bytes[headerLength]) << 8 | Int(bytes[headerLength + 1])
        let start = headerLength + 2
        guard bytes.count >= start + length else { return nil }
        return (Data(bytes[start ..< start + length]), Data(bytes[(start + length)...]))
    }

    static func openBox(_ box: Data, key: SymmetricKey, identity: NoteRecordIdentity) -> Data? {
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box) else { return nil }
        return try? ChaChaPoly.open(sealed, using: key, authenticating: associatedData(identity))
    }

    private static func header(_ kind: NoteRecordKind) -> Data {
        var header = magic
        header.append(version)
        header.append(kind.rawValue)
        return header
    }

    /// The header, the note's ID, the run's ID (zero for none) and the sequence number, big-endian.
    private static func associatedData(_ identity: NoteRecordIdentity) -> Data {
        var data = header(identity.kind)
        data.append(bytes(of: identity.noteID))
        data.append(bytes(of: identity.runID ?? zeroID))
        withUnsafeBytes(of: identity.sequence.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }
}

/// One content key to the vault's public key, and the records sealed under it: a run's start and segments share
/// one (ARCHITECTURE.md, "Notes", Sealing). Only the public key is needed. The key lives as long as this value.
struct NoteRunSealer {
    private let key: SymmetricKey
    private let encapsulatedKey: Data

    init(publicKey: Curve25519.KeyAgreement.PublicKey) throws {
        (key, encapsulatedKey) = try NoteSealing.makeContentKey(to: publicKey)
    }

    func seal(_ plaintext: Data, as identity: NoteRecordIdentity) throws -> Data {
        try NoteSealing.record(plaintext, as: identity, key: key, keyMaterial: encapsulatedKey)
    }
}

import CryptoKit
import Foundation

/// Sealing (ARCHITECTURE.md, "Notes", Sealing, and Secret and keys): a record opens only as what it was sealed as
/// and only with the vault's private key, sealing needs only the public key, and a record holds nothing readable.
/// Every text is invented.
enum NoteSealingTests {
    static var tests: [TestCase] {
        [
            ("recordOpensOnlyAsWhatItIs", testRecordOpensOnlyAsWhatItIs),
            ("recordOpensOnlyWithThePrivateKey", testRecordOpensOnlyWithThePrivateKey),
            ("aRunSealsWithThePublicKeyAlone", testARunSealsWithThePublicKeyAlone),
            ("recordHoldsNothingReadable", testRecordHoldsNothingReadable),
            ("alteredRecordDoesNotOpen", testAlteredRecordDoesNotOpen),
            ("keyPairDerivesFromTheSecret", testKeyPairDerivesFromTheSecret),
        ]
    }

    private static let noteA = UUID(uuidString: "00000000-0000-4000-8000-00000000E001")!
    private static let noteB = UUID(uuidString: "00000000-0000-4000-8000-00000000E002")!
    private static let runA = UUID(uuidString: "00000000-0000-4000-8000-00000000F001")!
    private static let runB = UUID(uuidString: "00000000-0000-4000-8000-00000000F002")!
    private static let plaintext = Data("Water the invented ferns on Tuesday".utf8)

    private static func keys() -> Curve25519.KeyAgreement.PrivateKey {
        NoteVaultKeys.privateKey(for: NoteVaultKeys.makeSecret())!
    }

    private static func testRecordOpensOnlyAsWhatItIs() {
        let privateKey = keys()
        let identity = NoteRecordIdentity.segment(noteA, run: runA, sequence: 2)
        let record = try! NoteSealing.seal(plaintext, as: identity, to: privateKey.publicKey)
        TestSupport.expectEqual(NoteSealing.open(record, as: identity, with: privateKey), plaintext)
        let others: [NoteRecordIdentity] = [
            .segment(noteB, run: runA, sequence: 2),
            .segment(noteA, run: runB, sequence: 2),
            .segment(noteA, run: runA, sequence: 1),
            .segment(noteA, run: runA, sequence: 3),
            .runStart(noteA, run: runA),
            .body(noteA),
        ]
        for other in others {
            TestSupport.expect(NoteSealing.open(record, as: other, with: privateKey) == nil, "opened as \(other)")
        }
        let body = try! NoteSealing.seal(plaintext, as: .body(noteA), to: privateKey.publicKey)
        TestSupport.expectEqual(NoteSealing.open(body, as: .body(noteA), with: privateKey), plaintext)
        TestSupport.expect(NoteSealing.open(body, as: .body(noteB), with: privateKey) == nil, "a body opened as another note's")
    }

    private static func testRecordOpensOnlyWithThePrivateKey() {
        let privateKey = keys()
        let record = try! NoteSealing.seal(plaintext, as: .body(noteA), to: privateKey.publicKey)
        TestSupport.expect(NoteSealing.open(record, as: .body(noteA), with: keys()) == nil, "opened with another key")
    }

    private static func testARunSealsWithThePublicKeyAlone() {
        let privateKey = keys()
        let publicKey = NoteVaultKeys.publicKey(privateKey.publicKey.rawRepresentation)!
        let sealer = try! NoteRunSealer(publicKey: publicKey)
        let pieces = ["First invented piece", "second one", "and a third"]
        let records = pieces.enumerated().map { index, piece in
            try! sealer.seal(Data(piece.utf8), as: .segment(noteA, run: runA, sequence: UInt32(index + 1)))
        }
        let opened = records.enumerated().map { index, record in
            NoteSealing.open(record, as: .segment(noteA, run: runA, sequence: UInt32(index + 1)), with: privateKey)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        TestSupport.expectEqual(opened, pieces.map { Optional($0) })
    }

    private static func testRecordHoldsNothingReadable() {
        let privateKey = keys()
        let record = try! NoteSealing.seal(plaintext, as: .body(noteA), to: privateKey.publicKey)
        TestSupport.expect(!noteBytes(record, contain: "invented ferns"), "the record holds its plaintext")
        TestSupport.expect(!noteBytes(record, contain: noteA.uuidString), "the record names its note")
        let again = try! NoteSealing.seal(plaintext, as: .body(noteA), to: privateKey.publicKey)
        TestSupport.expect(record != again, "two seals of one plaintext are the same")
    }

    private static func testAlteredRecordDoesNotOpen() {
        let privateKey = keys()
        let record = try! NoteSealing.seal(plaintext, as: .body(noteA), to: privateKey.publicKey)
        for index in [0, 5, 10, record.count / 2, record.count - 1] {
            var altered = record
            altered[index] ^= 0x01
            TestSupport.expect(NoteSealing.open(altered, as: .body(noteA), with: privateKey) == nil,
                               "a record altered at byte \(index) opened")
        }
        TestSupport.expect(NoteSealing.open(record.prefix(record.count - 1), as: .body(noteA), with: privateKey) == nil,
                           "a cut record opened")
    }

    private static func testKeyPairDerivesFromTheSecret() {
        let secret = NoteVaultKeys.makeSecret()
        TestSupport.expectEqual(secret.count, 32)
        TestSupport.expectEqual(NoteVaultKeys.privateKey(for: secret)!.publicKey.rawRepresentation,
                                NoteVaultKeys.privateKey(for: secret)!.publicKey.rawRepresentation)
        TestSupport.expect(NoteVaultKeys.privateKey(for: NoteVaultKeys.makeSecret())!.publicKey.rawRepresentation
                           != NoteVaultKeys.privateKey(for: secret)!.publicKey.rawRepresentation, "two secrets, one key")
        TestSupport.expect(NoteVaultKeys.privateKey(for: secret.prefix(31)) == nil, "a short secret derived a key")
    }
}

/// Recovery codes (ARCHITECTURE.md, "Notes", Recovery code): how they are shown and read, and that a wrap opens only
/// with its code.
enum NoteRecoveryCodeTests {
    static var tests: [TestCase] {
        [
            ("shownAsEightGroupsOfFour", testShownAsEightGroupsOfFour),
            ("readsWhatItShows", testReadsWhatItShows),
            ("readingForgivesCaseSpacingAndLookalikes", testReadingForgivesCaseSpacingAndLookalikes),
            ("malformedCodesAreRefused", testMalformedCodesAreRefused),
            ("wrapOpensOnlyWithItsCode", testWrapOpensOnlyWithItsCode),
        ]
    }

    private static func testShownAsEightGroupsOfFour() {
        let shown = NoteRecoveryCode.make().displayText
        let groups = shown.split(separator: "-", omittingEmptySubsequences: false)
        TestSupport.expectEqual(groups.count, 8)
        TestSupport.expect(groups.allSatisfy { $0.count == 4 }, "groups are not of four: \(groups.map(\.count))")
        TestSupport.expect(shown.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ-".contains($0) },
                           "a symbol outside Crockford base32")
        TestSupport.expect(NoteRecoveryCode.make() != NoteRecoveryCode.make(), "two codes are the same")
        TestSupport.expectEqual(NoteRecoveryCode.make().bits.count * 8, 160)
    }

    private static func testReadsWhatItShows() {
        for _ in 0 ..< 50 {
            let code = NoteRecoveryCode.make()
            TestSupport.expectEqual(NoteRecoveryCode(code.displayText), code)
        }
    }

    private static func testReadingForgivesCaseSpacingAndLookalikes() {
        let canonical = NoteRecoveryCode("0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ")
        TestSupport.expect(canonical != nil, "a valid code was refused")
        TestSupport.expectEqual(NoteRecoveryCode("o123 4567 89ab cdef ghjk mnpq rstv wxyz"), canonical)
        TestSupport.expectEqual(NoteRecoveryCode("O1234567-89AB-CDEF-GHJKMNPQRSTVWXYZ"), canonical)
        TestSupport.expectEqual(NoteRecoveryCode("0I23-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ"), canonical)
        TestSupport.expectEqual(NoteRecoveryCode("0l23-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ"), canonical)
    }

    private static func testMalformedCodesAreRefused() {
        let malformed = [
            "", "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXY", "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ0",
            "U123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ", "0123_4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ",
        ]
        for text in malformed {
            TestSupport.expect(NoteRecoveryCode(text) == nil, "'\(text)' was read as a code")
        }
    }

    private static func testWrapOpensOnlyWithItsCode() {
        let secret = NoteVaultKeys.makeSecret()
        let code = NoteRecoveryCode.make()
        let wrap = try! code.wrap(secret)
        TestSupport.expectEqual(code.unwrap(wrap), secret)
        TestSupport.expect(NoteRecoveryCode.make().unwrap(wrap) == nil, "another code opened the wrap")
        TestSupport.expect(wrap.range(of: secret) == nil, "the wrap holds the secret")
    }
}

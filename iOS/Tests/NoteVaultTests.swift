import Foundation

/// The vault (ARCHITECTURE.md, "Notes", Vault and Storage): its states, making one, unlocking through the key store,
/// locking, the recovery code and erasing, against the fake key store and a temporary notes directory. Every text is
/// invented.
enum NoteVaultTests {
    static var tests: [TestCase] {
        [
            ("noVaultUntilOneIsMade", testNoVaultUntilOneIsMade),
            ("noPasscodeNoVault", testNoPasscodeNoVault),
            ("makingAVaultLeavesItUnlockedAndEmpty", testMakingAVaultLeavesItUnlockedAndEmpty),
            ("unlockingAsksTheUser", testUnlockingAsksTheUser),
            ("cancelledAuthenticationLeavesItLocked", testCancelledAuthenticationLeavesItLocked),
            ("lockingDropsAccess", testLockingDropsAccess),
            ("aLockWhileTheUserAuthenticatesWins", testALockWhileTheUserAuthenticatesWins),
            ("unlockRewritesAWrongPublicKey", testUnlockRewritesAWrongPublicKey),
            ("notesWithoutTheSecretAreSecretMissing", testNotesWithoutTheSecretAreSecretMissing),
            ("recoveryCodeRestoresTheSecret", testRecoveryCodeRestoresTheSecret),
            ("aNewRecoveryCodeReplacesTheOld", testANewRecoveryCodeReplacesTheOld),
            ("recoveryCodeNeedsTheVaultUnlocked", testRecoveryCodeNeedsTheVaultUnlocked),
            ("eraseRemovesEverything", testEraseRemovesEverything),
            ("eraseIsRefusedWhileARunRecords", testEraseIsRefusedWhileARunRecords),
            ("noRunBeginsDuringAnErase", testNoRunBeginsDuringAnErase),
            ("notesAreKeptInBackups", testNotesAreKeptInBackups),
        ]
    }

    private static func testNoVaultUntilOneIsMade() {
        let fixture = NoteFixture()
        TestSupport.expectEqual(fixture.vault.state, .noVault)
        TestSupport.expect(fixture.vault.canMakeVault, "a vault cannot be made with a passcode")
        TestSupport.expectEqual(Result { try fixture.vault.unlock(prompt: "Read your notes") }.noteError, .noVault)
        TestSupport.expectEqual(Result { try fixture.recorder.beginRun(.newNote) }.noteError, .noVault)
    }

    private static func testNoPasscodeNoVault() {
        let fixture = NoteFixture()
        fixture.keyStore.deviceHasPasscode = false
        TestSupport.expect(!fixture.vault.canMakeVault, "a vault can be made without a passcode")
        TestSupport.expectEqual(Result { try fixture.vault.makeVault() }.noteError, .noPasscode)
        TestSupport.expectEqual(fixture.vault.state, .noVault)
        TestSupport.expect(fixture.keyStore.secret == nil, "a secret was stored")
    }

    private static func testMakingAVaultLeavesItUnlockedAndEmpty() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
        TestSupport.expectEqual(try! fixture.vault.notes(), [])
        TestSupport.expect(fixture.keyStore.secret?.count == 32, "no secret was stored")
        TestSupport.expect(fixture.files()["vault-public-key"]?.count == 32, "no public key was written")
        TestSupport.expect(!fixture.vault.canMakeVault, "a second vault can be made")
        TestSupport.expectEqual(Result { try fixture.vault.makeVault() }.noteError, .vaultExists)
        fixture.vault.lock()
        TestSupport.expectEqual(fixture.vault.state, .locked)
        TestSupport.expectEqual(Result { try fixture.vault.makeVault() }.noteError, .vaultExists)
    }

    private static func testUnlockingAsksTheUser() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.record(["An invented errand"])
        fixture.relaunch()
        TestSupport.expectEqual(fixture.vault.state, .locked)
        try! fixture.vault.unlock(prompt: "Read your notes")
        TestSupport.expectEqual(fixture.keyStore.prompts, ["Read your notes"])
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
        TestSupport.expectEqual(fixture.noteTexts(), ["An invented errand"])
        try! fixture.vault.unlock(prompt: "Again")
        TestSupport.expectEqual(fixture.keyStore.prompts, ["Read your notes"])
    }

    private static func testCancelledAuthenticationLeavesItLocked() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.vault.lock()
        fixture.keyStore.userCancels = true
        TestSupport.expectEqual(Result { try fixture.vault.unlock(prompt: "Read your notes") }.noteError,
                                .authenticationCancelled)
        TestSupport.expectEqual(fixture.vault.state, .locked)
        TestSupport.expectEqual(Result { try fixture.vault.notes() }.noteError, .locked)
    }

    private static func testLockingDropsAccess() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = fixture.record(["A synthetic shopping list"])
        try! fixture.vault.mergePendingRuns()
        TestSupport.expectEqual(fixture.noteTexts(), ["A synthetic shopping list"])
        fixture.vault.lock()
        TestSupport.expectEqual(fixture.vault.state, .locked)
        let calls: [(String, () throws -> Void)] = [
            ("notes", { _ = try fixture.vault.notes() }),
            ("note", { _ = try fixture.vault.note(id) }),
            ("searchIndex", { _ = try fixture.vault.searchIndex() }),
            ("replaceText", { try fixture.vault.replaceText(of: id, with: "Changed") }),
            ("deleteNote", { try fixture.vault.deleteNote(id) }),
            ("makeRecoveryCode", { _ = try fixture.vault.makeRecoveryCode() }),
            ("unreadableNoteCount", { _ = try fixture.vault.unreadableNoteCount() }),
        ]
        for (name, call) in calls {
            TestSupport.expect(Result { try call() }.noteError == .locked, "\(name) worked on a locked vault")
        }
        // Merging waits for the next unlock, and the note is as it was.
        try! fixture.vault.mergePendingRuns()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["A synthetic shopping list"])
    }

    private static func testALockWhileTheUserAuthenticatesWins() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.vault.lock()
        fixture.keyStore.whileAsking = { fixture.vault.lock() }
        TestSupport.expectEqual(Result { try fixture.vault.unlock(prompt: "Read your notes") }.noteError, .locked)
        TestSupport.expectEqual(fixture.vault.state, .locked)
        fixture.keyStore.whileAsking = nil
        fixture.unlock()
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
    }

    private static func testUnlockRewritesAWrongPublicKey() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let publicKey = fixture.files()["vault-public-key"]!
        fixture.vault.lock()
        let url = fixture.directory.appendingPathComponent("vault-public-key")
        try! NoteVaultKeys.privateKey(for: NoteVaultKeys.makeSecret())!.publicKey.rawRepresentation.write(to: url)
        fixture.unlock()
        TestSupport.expectEqual(fixture.files()["vault-public-key"], publicKey)
        fixture.vault.lock()
        try! FileManager.default.removeItem(at: url)
        fixture.unlock()
        TestSupport.expectEqual(fixture.files()["vault-public-key"], publicKey)
    }

    private static func testNotesWithoutTheSecretAreSecretMissing() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.record(["An invented reminder"])
        fixture.keyStore.secret = nil   // as on another iPhone, or once the passcode was turned off
        fixture.relaunch()
        TestSupport.expectEqual(fixture.vault.state, .secretMissing)
        TestSupport.expect(!fixture.vault.canMakeVault, "a vault can be made over notes")
        TestSupport.expectEqual(Result { try fixture.vault.unlock(prompt: "Read your notes") }.noteError, .secretMissing)
        // Nothing readable is on disk without the secret.
        for (name, data) in fixture.files() {
            TestSupport.expect(!noteBytes(data, contain: "invented reminder"), "\(name) holds the note's text")
        }
    }

    private static func testRecoveryCodeRestoresTheSecret() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        TestSupport.expect(!fixture.vault.hasRecoveryCode, "a recovery code before one was made")
        let code = try! fixture.vault.makeRecoveryCode()
        TestSupport.expect(fixture.vault.hasRecoveryCode, "no recovery code after one was made")
        let secret = fixture.keyStore.secret
        fixture.record(["Invented notes from a restored backup"])
        fixture.keyStore.secret = nil
        fixture.relaunch()
        TestSupport.expectEqual(fixture.vault.state, .secretMissing)

        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: NoteRecoveryCode.make().displayText) }.noteError,
                                .wrongRecoveryCode)
        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: "not a code") }.noteError,
                                .malformedRecoveryCode)
        TestSupport.expectEqual(fixture.vault.state, .secretMissing)
        TestSupport.expect(fixture.keyStore.secret == nil, "a wrong code stored a secret")

        try! fixture.vault.restore(recoveryCode: code.displayText.lowercased())
        TestSupport.expectEqual(fixture.keyStore.secret, secret)
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented notes from a restored backup"])
        fixture.relaunch()
        fixture.unlock()
        TestSupport.expectEqual(fixture.noteTexts(), ["Invented notes from a restored backup"])
        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: code.displayText) }.noteError,
                                .vaultExists)
    }

    private static func testANewRecoveryCodeReplacesTheOld() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let old = try! fixture.vault.makeRecoveryCode()
        let new = try! fixture.vault.makeRecoveryCode()
        fixture.keyStore.secret = nil
        fixture.relaunch()
        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: old.displayText) }.noteError,
                                .wrongRecoveryCode)
        try! fixture.vault.restore(recoveryCode: new.displayText)
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
    }

    private static func testRecoveryCodeNeedsTheVaultUnlocked() {
        let fixture = NoteFixture()
        TestSupport.expectEqual(Result { try fixture.vault.makeRecoveryCode() }.noteError, .locked)
        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: NoteRecoveryCode.make().displayText) }.noteError,
                                .noVault)
        try! fixture.vault.makeVault()
        fixture.record(["Invented"])
        fixture.keyStore.secret = nil
        fixture.relaunch()
        TestSupport.expectEqual(Result { try fixture.vault.restore(recoveryCode: NoteRecoveryCode.make().displayText) }.noteError,
                                .noRecoveryCode)
    }

    private static func testEraseRemovesEverything() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        _ = try! fixture.vault.makeRecoveryCode()
        fixture.record(["An invented diary entry"])
        try! fixture.vault.eraseAll()
        TestSupport.expectEqual(fixture.vault.state, .noVault)
        TestSupport.expect(fixture.keyStore.secret == nil, "the secret survived")
        TestSupport.expect(!FileManager.default.fileExists(atPath: fixture.directory.path), "the notes directory survived")
        TestSupport.expect(fixture.vault.canMakeVault, "no new vault after erasing")
        // Erasing what a lost secret left behind.
        try! fixture.vault.makeVault()
        fixture.record(["Another invented entry"])
        fixture.keyStore.secret = nil
        fixture.relaunch()
        try! fixture.vault.eraseAll()
        TestSupport.expectEqual(fixture.vault.state, .noVault)
    }

    private static func testEraseIsRefusedWhileARunRecords() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let writer = try! fixture.recorder.beginRun(.newNote)
        try! writer.append("Invented words")
        TestSupport.expectEqual(Result { try fixture.vault.eraseAll() }.noteError, .noteIsRecording)
        TestSupport.expectEqual(fixture.vault.state, .unlocked)
        writer.end()
        try! fixture.vault.eraseAll()
        TestSupport.expectEqual(fixture.vault.state, .noVault)
    }

    private static func testNoRunBeginsDuringAnErase() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        var during: NoteError?
        fixture.keyStore.whileDeleting = { during = Result { try fixture.recorder.beginRun(.newNote) }.noteError }
        try! fixture.vault.eraseAll()
        TestSupport.expectEqual(during, .noVault)
        TestSupport.expectEqual(fixture.vault.state, .noVault)
        TestSupport.expect(!FileManager.default.fileExists(atPath: fixture.directory.path), "the notes directory survived")
    }

    private static func testNotesAreKeptInBackups() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        let id = fixture.record(["Invented"])
        try! fixture.vault.mergePendingRuns()
        for url in [fixture.directory, fixture.noteDirectory(id)] {
            let values = try! url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            TestSupport.expectEqual(values.isExcludedFromBackup, false)
        }
    }
}

extension Result where Failure == Error {
    /// The `NoteError` this failed with; nil for success or another error.
    var noteError: NoteError? {
        guard case .failure(let error) = self else { return nil }
        return error as? NoteError
    }
}

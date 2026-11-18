import Foundation
import LocalAuthentication
import Security

/// The vault secret in one Keychain item (ARCHITECTURE.md, "Notes", Key store): this iPhone only, only while a
/// passcode is set, and released only after Face ID, Touch ID or the passcode, so reading it is the
/// authentication. Its service and account are `NoteStoredNames`'. The simulator has no passcode and enforces no
/// protection, so there the item has no access control. Nothing here logs.
final class KeychainNoteKeyStore: NoteKeyStore {
    var deviceHasPasscode: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #endif
    }

    func hasSecret() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = itemQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // An item that would need the user to authenticate exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func storeSecret(_ secret: Data) throws {
        try deleteSecret()
        var query = itemQuery
        query[kSecValueData as String] = secret
        query[kSecAttrSynchronizable as String] = false
        #if targetEnvironment(simulator)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, nil) else {
            throw NoteKeyStoreError.failed
        }
        query[kSecAttrAccessControl as String] = access
        #endif
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw NoteKeyStoreError.failed }
    }

    /// Blocks while the user authenticates; never call it on the main thread.
    func readSecret(prompt: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = prompt
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let secret = result as? Data else { throw NoteKeyStoreError.failed }
            return secret
        case errSecItemNotFound:
            throw NoteKeyStoreError.notFound
        case errSecUserCanceled, errSecAuthFailed:
            throw NoteKeyStoreError.cancelled
        default:
            throw NoteKeyStoreError.failed
        }
    }

    func deleteSecret() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NoteKeyStoreError.failed }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: NoteStoredNames.keychainService,
            kSecAttrAccount as String: NoteStoredNames.keychainAccount,
        ]
    }
}

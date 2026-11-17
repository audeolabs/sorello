import Foundation

/// The names an installed copy stores notes under (ARCHITECTURE.md, "Identifiers", Stored names, and "Notes",
/// Storage). Kept in every build: an update must find the notes, and the vault secret, its user already has.
enum NoteStoredNames {
    /// The notes directory, in `Library/Application Support` of the app's own container.
    static let directory = "SorelloNotes"
    /// The vault's public key, raw.
    static let publicKey = "vault-public-key"
    /// The vault secret, wrapped by the recovery code.
    static let recoveryWrap = "recovery-wrap"
    /// A note's directory: `note-<UUID>`.
    static let notePrefix = "note-"
    /// A note's sealed body.
    static let body = "body"
    /// A run's directory in its note's: `run-<order>-<UUID>`.
    static let runPrefix = "run-"
    /// A run's start: its place and its start date.
    static let runStart = "start"
    /// A run's segment: `segment-<sequence>`, from 1.
    static let segmentPrefix = "segment-"
    /// A note's directory while it is deleted: `.deleted-<UUID>`.
    static let deletedPrefix = ".deleted-"
    /// Ends every staging file's name in the notes directory.
    static let stagingSuffix = ".tmp"
    /// The Keychain item that holds the vault secret: a generic password with this service and account.
    static let keychainService = "SorelloNotes"
    static let keychainAccount = "vault-secret"
}

import Foundation
import Synchronization

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// One immutable view of the dictionary for one dictation: the words that apply in its app, and which revision they
/// came from. Decoding never reads mutable dictionary state, so editing the dictionary while a dictation is being
/// transcribed changes nothing for it.
public struct DictionarySnapshot: Sendable, Equatable {
    /// Raised by every change to the dictionary.
    public let revision: UInt64
    /// The entries that apply everywhere plus those limited to `appID`, in entry order.
    public let entries: [DictionaryEntry]
    /// The app whose limited words `entries` includes; nil when the app has none, so every such app shares one graph.
    public let appID: String?

    public init(revision: UInt64, entries: [DictionaryEntry], appID: String? = nil) {
        self.revision = revision
        self.entries = entries
        self.appID = appID
    }

    /// No words: decoding takes the unbiased path.
    public static let empty = DictionarySnapshot(revision: 0, entries: [])
}

/// The dictionary's file, `dictionary.json` (ARCHITECTURE.md, section 7), and the one place it changes. Every change
/// is validated, written atomically, and only then published with a new revision (DESIGN §3.3). Reads hand out
/// values, so the speech engine can take a snapshot on its own thread while Settings edits the dictionary.
public final class DictionaryStore: Sendable {
    /// What opening the store found.
    public enum Opening: Equatable, Sendable {
        /// There was no file; the dictionary starts empty.
        case new
        case loaded
        /// The file is there but could not be opened, as when its permissions forbid it. It is left alone: not moved,
        /// deleted or written over. The dictionary starts empty, and each change tries to open the file again first.
        case unopenable
        /// The file could be read but not as a dictionary. It was moved to `movedTo` and replaced with an empty one,
        /// or, when it could not be moved (nil), left in place and the store refuses changes until the next launch.
        case replacedUnreadable(movedTo: URL?)
    }

    /// Whether changes may be written to the file.
    private enum FileState: Sendable {
        case usable
        /// The file could not be opened; nothing is written until it can be.
        case unopened
        /// An unreadable file could not be moved aside; nothing is written over it.
        case readOnly
    }

    private struct State: Sendable {
        var dictionary: ScopedDictionary
        var revision: UInt64
        var file: FileState
    }

    private let fileURL: URL
    private let encoder: BPEEncoder?
    private let editor: ScopedDictionaryEditor
    private let state: Mutex<State>
    public let opening: Opening

    /// Loads `fileURL`, creating its directory, readable only by the user, if it is missing. `encoder` is the speech
    /// model's vocabulary; without it the dictionary loads but cannot be changed.
    public init(fileURL: URL, encoder: BPEEncoder?) {
        self.fileURL = fileURL
        self.encoder = encoder
        editor = ScopedDictionaryEditor(encoder: encoder)
        let (opening, dictionary, file) = Self.load(fileURL, encoder: encoder)
        self.opening = opening
        state = Mutex(State(dictionary: dictionary, revision: 1, file: file))
    }

    /// Reads the file. A file that cannot be opened is left alone; one that opens but is not a dictionary is moved
    /// aside and replaced with an empty one.
    private static func load(_ url: URL, encoder: BPEEncoder?) -> (Opening, ScopedDictionary, FileState) {
        // Only "no such file" means there is no dictionary. Anything else, such as a directory that may not be
        // searched, means there may be one we cannot see, which must never be written over.
        var status = stat()
        if lstat(url.path, &status) != 0 {
            return errno == ENOENT ? (.new, ScopedDictionary(), .usable) : (.unopenable, ScopedDictionary(), .unopened)
        }
        guard let data = try? Data(contentsOf: url) else { return (.unopenable, ScopedDictionary(), .unopened) }
        if let dictionary = DictionaryFile.decode(data, encoder: encoder) { return (.loaded, dictionary, .usable) }
        guard let aside = moveAside(url) else { return (.replacedUnreadable(movedTo: nil), ScopedDictionary(), .readOnly) }
        _ = writeAtomically(DictionaryFile.encode(ScopedDictionary()), to: url)
        return (.replacedUnreadable(movedTo: aside), ScopedDictionary(), .usable)
    }

    /// The whole dictionary now.
    public var dictionary: ScopedDictionary { state.withLock { $0.dictionary } }

    /// Raised by every change.
    public var revision: UInt64 { state.withLock { $0.revision } }

    /// Whether changes can be made: the vocabulary is loaded and nothing forbids writing the file. A file that could
    /// not be opened is tried again by the next change.
    public var canEdit: Bool { editor.canEdit && state.withLock { $0.file } != .readOnly }

    /// The words for a dictation into `appID` (nil: no app, as for a Run Log retry), with the revision they belong to.
    public func snapshot(for appID: String?) -> DictionarySnapshot {
        state.withLock { state in
            let words = state.dictionary.decodingWords(for: appID)
            return DictionarySnapshot(revision: state.revision, entries: words.entries, appID: words.appID)
        }
    }

    /// Adds a word, or edits the entry `original` (its text may change), limited to `apps` (none: everywhere).
    public func save(text: String, strength: Float, apps: Set<String> = [],
                     replacing original: DictionaryKey? = nil) throws(DictionaryChangeError) {
        try change { editor.saving(text: text, strength: strength, apps: apps, replacing: original, in: $0) }
    }

    /// Removes an entry and its app limits. Returns false when there was no such entry.
    @discardableResult
    public func remove(_ key: DictionaryKey) throws(DictionaryChangeError) -> Bool {
        try change { editor.removing(key, in: $0) }
    }

    /// A suggestion's "Add to <App>" (`app`) or "Add everywhere" (nil). An existing word keeps its text, takes the
    /// higher strength, and gains the app unless it already applies everywhere.
    public func add(_ word: String, strength: Float, to app: DictionaryApp?) throws(DictionaryChangeError) {
        try change { editor.adding(word, strength: strength, to: app, in: $0) }
    }

    /// Adds an app words can be limited to, or updates a known app's name.
    public func register(_ app: DictionaryApp) throws(DictionaryChangeError) {
        try change { editor.registering(app, in: $0) }
    }

    /// Forgets an app and removes the words only it had. Returns false when the app was not known.
    @discardableResult
    public func removeApp(id: String) throws(DictionaryChangeError) -> Bool {
        try change { editor.removingApp(id, in: $0) }
    }

    /// "Don't suggest": the key is never offered as a suggestion again.
    public func ignore(_ key: DictionaryKey) throws(DictionaryChangeError) {
        try change { editor.ignoring(key, in: $0) }
    }

    /// Takes a key off the ignore list. Returns false when it was not on it.
    @discardableResult
    public func unignore(_ key: DictionaryKey) throws(DictionaryChangeError) -> Bool {
        try change { editor.unignoring(key, in: $0) }
    }

    /// Validates, writes, then publishes. Returns whether anything changed; an edit that changes nothing is neither
    /// written nor published.
    @discardableResult
    private func change(
        _ propose: (ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError>?
    ) throws(DictionaryChangeError) -> Bool {
        let outcome: Result<Bool, DictionaryChangeError> = state.withLock { state in
            guard editor.canEdit else { return .failure(.noVocabulary) }
            if state.file == .unopened {
                let (_, dictionary, file) = Self.load(fileURL, encoder: encoder)
                guard file != .unopened else { return .failure(.notSaved) }
                if dictionary != state.dictionary {
                    state.dictionary = dictionary
                    state.revision += 1
                }
                state.file = file
            }
            guard let proposed = propose(state.dictionary) else { return .success(false) }
            switch proposed {
            case .failure(let error):
                return .failure(error)
            case .success(let updated):
                guard updated != state.dictionary else { return .success(false) }
                guard state.file == .usable, Self.writeAtomically(DictionaryFile.encode(updated), to: fileURL) else {
                    return .failure(.notSaved)
                }
                state.dictionary = updated
                state.revision += 1
                return .success(true)
            }
        }
        return try outcome.get()
    }

    /// Moves an unreadable file to `<name>-unreadable-<seconds since 1970>.json` beside it, never over another file.
    private static func moveAside(_ url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let target = directory.appendingPathComponent("\(stem)-unreadable-\(stamp)\(suffix).json")
            do {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            } catch {
                if !FileManager.default.fileExists(atPath: target.path) { return nil }
            }
        }
        return nil
    }

    /// Writes `data` to a new file readable only by the user, flushes it, and renames it over `url`, so the file is
    /// always either the old dictionary or the new one. The directory is created, private, if it is missing.
    static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        var written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        written = written && fsync(descriptor) == 0
        close(descriptor)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}

import DictionaryKit
import Foundation

// DESIGN refers to ../docs/dictionary/DESIGN.md. The rules for an entry, the tokenizer and decoding are the shared
// `DictionaryKit`'s. How the iPhone keeps its dictionary is its own: the app's `UserDefaults`, under the keys and in the
// payloads the earlier build of this app wrote, which `DictionaryKit` does not offer (the Mac app keeps its dictionary
// in a file of another shape). These types are ported from that earlier build's shared dictionary, unchanged in what
// they read, write and refuse (ARCHITECTURE.md, "Custom dictionary").

/// The iPhone app's dictionary: entries and the ignore list, with the rules of DESIGN §1.1. The app shows no ignore
/// list, but keeps what is stored.
struct SavedDictionary: Equatable {
    enum MutationError: Error, Equatable {
        case full
        /// The identity or ignore key fails pin P6; nothing is changed.
        case invalidKey
    }

    /// In the order they were added.
    private(set) var entries: [DictionaryEntry] = []
    /// Keys never offered as suggestions, in the order they were ignored.
    private(set) var ignore: [DictionaryKey] = []

    func contains(_ key: DictionaryKey) -> Bool { entries.contains { $0.key == key } }

    func isIgnored(_ key: DictionaryKey) -> Bool { ignore.contains(key) }

    /// Adds, or replaces the entry with the same identity key.
    mutating func upsert(_ entry: DictionaryEntry) -> MutationError? {
        let key = entry.key
        guard key.isValid else { return .invalidKey }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = entry
            return nil
        }
        guard entries.count < DictionaryValidation.capacity else { return .full }
        entries.append(entry)
        return nil
    }

    @discardableResult
    mutating func remove(_ key: DictionaryKey) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func addIgnore(_ key: DictionaryKey) -> MutationError? {
        guard key.isValid else { return .invalidKey }
        guard !ignore.contains(key) else { return nil }
        guard ignore.count < DictionaryValidation.ignoreCapacity else { return .full }
        ignore.append(key)
        return nil
    }
}

enum DictionaryEditError: Error, Equatable {
    /// No speech-model vocabulary: §1.1's encodability check cannot run, so
    /// nothing may change (an unchecked entry could make storage unreadable
    /// once a vocabulary is back).
    case noVocabulary
    case invalid(DictionaryEntryError)
    case full
    case invalidKey

    /// Content-free: never quotes the entry.
    var message: String {
        switch self {
        case .noVocabulary: return DictionaryEditor.unavailableMessage
        case .invalid(let error): return error.message
        case .full: return "The dictionary is full (\(DictionaryValidation.capacity) entries)."
        case .invalidKey: return DictionaryEntryError.unencodable.message
        }
    }
}

/// Every change to the dictionary goes through here. Each call returns the
/// proposed state; the caller persists it before publishing it. Loading never
/// needs this (it preserves saved data as is).
struct DictionaryEditor {
    static let unavailableMessage = "The dictionary needs the speech model, which isn’t available."

    let encoder: BPEEncoder?

    var canEdit: Bool { encoder != nil }

    /// Adds, or edits the entry `original` (its key may change).
    func saving(text: String, strength: Float, replacing original: DictionaryKey?,
                in dictionary: SavedDictionary) -> Result<SavedDictionary, DictionaryEditError> {
        guard let encoder else { return .failure(.noVocabulary) }
        switch DictionaryValidation.validate(text: text, strength: strength, encoder: encoder) {
        case .failure(let error):
            return .failure(.invalid(error))
        case .success(let entry):
            var updated = dictionary
            if let original, original != entry.key { updated.remove(original) }
            switch updated.upsert(entry) {
            case .full?: return .failure(.full)
            case .invalidKey?: return .failure(.invalidKey)
            case nil: return .success(updated)
            }
        }
    }

    /// nil when there is nothing to remove.
    func removing(_ key: DictionaryKey, in dictionary: SavedDictionary) -> Result<SavedDictionary, DictionaryEditError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        return updated.remove(key) ? .success(updated) : nil
    }
}

enum DictionaryStorageError: Error, Equatable {
    /// Content-free on purpose: errors never quote stored text.
    case unreadable
}

/// UserDefaults payloads (DESIGN §3.2): `{"version":1,"entries":[…]}` and
/// `{"version":1,"ignore":[…]}`. Loading validates everything; any failure
/// rejects the whole dictionary so the caller can preserve the raw data.
enum DictionaryStorage {
    static let version = 1
    /// Above the largest payload `encode` can produce (DESIGN §3.2), so whatever was saved loads again.
    static let maxBytes = 2 << 20

    /// An entry as the payload stores it.
    private struct StoredEntry: Codable {
        let text: String
        let strength: Float
    }

    private struct EntriesFile: Codable {
        let version: Int
        let entries: [StoredEntry]
    }

    private struct IgnoreFile: Codable {
        let version: Int
        let ignore: [String]
    }

    static func load(entriesData: Data?, ignoreData: Data?,
                     encoder: BPEEncoder?) -> Result<SavedDictionary, DictionaryStorageError> {
        var dictionary = SavedDictionary()
        if let entriesData {
            guard entriesData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(EntriesFile.self, from: entriesData),
                  file.version == version, file.entries.count <= DictionaryValidation.capacity else {
                return .failure(.unreadable)
            }
            var keys = Set<DictionaryKey>()
            for stored in file.entries {
                guard case .success(let entry) = DictionaryValidation.validate(text: stored.text, strength: stored.strength,
                                                                              encoder: encoder),
                      sameScalars(entry.text, stored.text),
                      keys.insert(entry.key).inserted,
                      dictionary.upsert(entry) == nil else {
                    return .failure(.unreadable)
                }
            }
        }
        if let ignoreData {
            guard ignoreData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(IgnoreFile.self, from: ignoreData),
                  file.version == version, file.ignore.count <= DictionaryValidation.ignoreCapacity else {
                return .failure(.unreadable)
            }
            for stored in file.ignore {
                // Stored exactly as saved: valid per pin P6, which includes being folded already, so the key's text
                // is the stored text itself; no duplicates.
                let key = DictionaryKey(stored)
                guard sameScalars(key.text, stored), key.isValid, !dictionary.isIgnored(key),
                      dictionary.addIgnore(key) == nil else {
                    return .failure(.unreadable)
                }
            }
        }
        return .success(dictionary)
    }

    static func encode(_ dictionary: SavedDictionary) -> (entries: Data, ignore: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = dictionary.entries.map { StoredEntry(text: $0.text, strength: $0.strength) }
        let entriesData = (try? encoder.encode(EntriesFile(version: version, entries: entries))) ?? Data()
        let ignore = (try? encoder.encode(IgnoreFile(version: version, ignore: dictionary.ignore.map(\.text)))) ?? Data()
        return (entriesData, ignore)
    }

    /// Exact scalar equality: Swift's `String ==` treats canonically equivalent text as equal (DESIGN §1.0).
    private static func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}

/// The dictionary in UserDefaults, under the keys the earlier build wrote, which are the Mac's too.
/// Callers must not save over data that failed to load: it stays untouched
/// until an explicit `remove`.
extension DictionaryStorage {
    // Kept from the earlier build: an installed copy has its dictionary under these keys (ARCHITECTURE.md,
    // "Identifiers", Stored names).
    static let entriesKey = "custom_dictionary"
    static let ignoreKey = "custom_dictionary_ignore"

    /// The data under `key`, nil when nothing is stored. A value of the wrong
    /// type is unreadable, never "missing".
    static func storedData(forKey key: String, in defaults: UserDefaults) -> Result<Data?, DictionaryStorageError> {
        guard let value = defaults.object(forKey: key) else { return .success(nil) }
        guard let data = value as? Data else { return .failure(.unreadable) }
        return .success(data)
    }

    /// Reads and validates the saved dictionary; never writes.
    static func load(from defaults: UserDefaults, encoder: BPEEncoder?) -> Result<SavedDictionary, DictionaryStorageError> {
        guard case .success(let entries) = storedData(forKey: entriesKey, in: defaults),
              case .success(let ignore) = storedData(forKey: ignoreKey, in: defaults) else {
            return .failure(.unreadable)
        }
        return load(entriesData: entries, ignoreData: ignore, encoder: encoder)
    }

    static func save(_ dictionary: SavedDictionary, to defaults: UserDefaults) {
        let encoded = encode(dictionary)
        defaults.set(encoded.entries, forKey: entriesKey)
        defaults.set(encoded.ignore, forKey: ignoreKey)
    }

    /// The explicit recovery for unreadable saved data.
    static func remove(from defaults: UserDefaults) {
        defaults.removeObject(forKey: entriesKey)
        defaults.removeObject(forKey: ignoreKey)
    }
}

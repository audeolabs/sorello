import DictionaryKit
import Foundation

// DESIGN refers to ../docs/dictionary/DESIGN.md. The dictionary itself is the shared `DictionaryKit`'s: its entries and
// their validation, its value (`CustomDictionary`) and its editor (`DictionaryEditor`). Only how the iPhone keeps it is
// the app's own: the app's `UserDefaults`, under the keys and in the payloads the earlier build of this app wrote, which
// `DictionaryKit` does not offer, because the Mac app keeps its dictionary in a file of another shape. What this reads,
// writes and refuses is unchanged from that build (ARCHITECTURE.md, "Custom dictionary").

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
                     encoder: BPEEncoder?) -> Result<CustomDictionary, DictionaryStorageError> {
        var entries: [DictionaryEntry] = [], ignore: [DictionaryKey] = []
        if let entriesData {
            guard entriesData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(EntriesFile.self, from: entriesData),
                  file.version == version, file.entries.count <= DictionaryValidation.capacity else {
                return .failure(.unreadable)
            }
            for stored in file.entries {
                // Stored exactly as validated: normalized already.
                guard case .success(let entry) = DictionaryValidation.validate(text: stored.text, strength: stored.strength,
                                                                              encoder: encoder),
                      sameScalars(entry.text, stored.text) else {
                    return .failure(.unreadable)
                }
                entries.append(entry)
            }
        }
        if let ignoreData {
            guard ignoreData.count <= maxBytes,
                  let file = try? JSONDecoder().decode(IgnoreFile.self, from: ignoreData),
                  file.version == version, file.ignore.count <= DictionaryValidation.ignoreCapacity else {
                return .failure(.unreadable)
            }
            for stored in file.ignore {
                // Stored exactly as saved: folded already (pin P6), so the key's text is the stored text itself.
                let key = DictionaryKey(stored)
                guard sameScalars(key.text, stored) else { return .failure(.unreadable) }
                ignore.append(key)
            }
        }
        // The dictionary refuses the rest: two entries with one key, a key ignored twice, a key that is not valid.
        guard let dictionary = CustomDictionary(entries: entries, ignore: ignore) else { return .failure(.unreadable) }
        return .success(dictionary)
    }

    static func encode(_ dictionary: CustomDictionary) -> (entries: Data, ignore: Data) {
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
    static func load(from defaults: UserDefaults, encoder: BPEEncoder?) -> Result<CustomDictionary, DictionaryStorageError> {
        guard case .success(let entries) = storedData(forKey: entriesKey, in: defaults),
              case .success(let ignore) = storedData(forKey: ignoreKey, in: defaults) else {
            return .failure(.unreadable)
        }
        return load(entriesData: entries, ignoreData: ignore, encoder: encoder)
    }

    static func save(_ dictionary: CustomDictionary, to defaults: UserDefaults) {
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

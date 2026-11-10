import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// The contents of `dictionary.json` (ARCHITECTURE.md, section 7; DESIGN §3.2):
///
///     {"apps":[{"id":…,"name":…}],
///      "entries":[{"apps":[…],"strength":…,"text":…}],
///      "ignore":[…],
///      "version":1}
///
/// JSON with sorted keys. An entry's `apps` is absent when it applies everywhere, and sorted otherwise. Decoding
/// validates everything and rejects the whole file on any failure, so the caller can move it aside.
enum DictionaryFile {
    static let version = 1
    /// Above the largest file `encode` can produce (1000 entries of 100 four-byte scalars, each limited to 32 apps
    /// with 155-character identifiers, 1000 ignored keys of 300 four-byte scalars and 32 apps with 100-scalar names:
    /// about 7 MiB), so whatever was saved loads again.
    static let maxBytes = 16 << 20

    private struct File: Codable {
        let apps: [AppRecord]
        let entries: [EntryRecord]
        let ignore: [String]
        let version: Int
    }

    private struct AppRecord: Codable {
        let id: String
        let name: String
    }

    private struct EntryRecord: Codable {
        let apps: [String]?
        let strength: Float
        let text: String
    }

    /// The dictionary in `data`, or nil when anything about it is invalid. Without a vocabulary the encodability check
    /// of §1.1 is skipped and nothing else.
    static func decode(_ data: Data, encoder: BPEEncoder?) -> ScopedDictionary? {
        guard data.count <= maxBytes, let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version, file.apps.count <= DictionaryAppScopes.appCapacity,
              file.entries.count <= DictionaryValidation.capacity,
              file.ignore.count <= DictionaryValidation.ignoreCapacity else {
            return nil
        }
        var result = ScopedDictionary()
        for record in file.apps {
            guard let app = DictionaryApp(id: record.id, name: record.name), DictionaryText.same(app.name, record.name),
                  result.scopes.app(id: app.id) == nil, result.scopes.register(app) == nil else {
                return nil
            }
        }
        for record in file.entries {
            // Stored exactly as validated: normalized, and no two entries share a key.
            guard case .success(let entry) = DictionaryValidation.validate(text: record.text, strength: record.strength,
                                                                          encoder: encoder),
                  DictionaryText.same(entry.text, record.text), !result.dictionary.contains(entry.key),
                  result.dictionary.upsert(entry) == nil else {
                return nil
            }
            guard let apps = record.apps else { continue }
            let ids = Set(apps)
            guard !ids.isEmpty, ids.count == apps.count, result.scopes.setApps(ids, for: entry.key) == nil else {
                return nil
            }
        }
        for stored in file.ignore {
            // Stored exactly as saved: valid per pin P6 (already folded), no repeats.
            let key = DictionaryKey(folded: Array(stored.unicodeScalars))
            guard key.isValid, !result.dictionary.isIgnored(key), result.dictionary.addIgnore(key) == nil else {
                return nil
            }
        }
        return result
    }

    static func encode(_ dictionary: ScopedDictionary) -> Data {
        func precedes(_ a: String, _ b: String) -> Bool {
            a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
        }
        let entries = dictionary.dictionary.entries.map { entry in
            let apps = dictionary.scopes.apps(for: entry.key)
            return EntryRecord(apps: apps.isEmpty ? nil : apps.sorted(by: precedes), strength: entry.strength,
                               text: entry.text)
        }
        let file = File(apps: dictionary.scopes.apps.map { AppRecord(id: $0.id, name: $0.name) }, entries: entries,
                        ignore: dictionary.dictionary.ignore.map(\.text), version: version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings, numbers and arrays cannot fail.
        return (try? encoder.encode(file)) ?? Data()
    }
}

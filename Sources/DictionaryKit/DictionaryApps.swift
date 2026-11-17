import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// An app a word can be limited to (DESIGN §3.6). The name is the last one seen, so a deleted app's words stay
/// listed under it.
public struct DictionaryApp: Hashable, Sendable {
    public static let maxIDLength = 155
    public static let maxNameScalars = 100

    public let id: String
    public let name: String

    /// nil unless `id` is a bundle identifier. The name is trimmed, loses its control characters and is cut to 100
    /// scalars; empty, it is the id.
    public init?(id: String, name: String?) {
        guard Self.isBundleIdentifier(id) else { return nil }
        self.id = id
        self.name = Self.normalizedName(name, id: id)
    }

    public static func isBundleIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxIDLength
            && id.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
            }
    }

    static func normalizedName(_ name: String?, id: String) -> String {
        let visible = DictionaryText.string((name ?? "").unicodeScalars.filter { !DictionaryText.isControl($0) })
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }
        return DictionaryText.string(trimmed.unicodeScalars.prefix(maxNameScalars))
    }
}

/// The known apps and which words are limited to them. A word without apps applies everywhere; the entries
/// themselves stay in `CustomDictionary`.
public struct DictionaryAppScopes: Equatable, Sendable {
    public static let appCapacity = 32

    /// In the order they became known.
    public private(set) var apps: [DictionaryApp] = []
    /// By identity key; never an empty set.
    private(set) var limits: [DictionaryKey: Set<String>] = [:]

    public init() {}

    public func app(id: String) -> DictionaryApp? { apps.first { $0.id == id } }

    /// The bundle identifiers `key` is limited to; empty when it applies everywhere.
    public func apps(for key: DictionaryKey) -> Set<String> { limits[key] ?? [] }

    /// How many words are limited to `appID`.
    public func wordCount(in appID: String) -> Int { limits.values.filter { $0.contains(appID) }.count }

    /// Adds an app, or updates the name of a known one in place.
    mutating func register(_ app: DictionaryApp) -> DictionaryChangeError? {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index] = app
            return nil
        }
        guard apps.count < Self.appCapacity else { return .appsFull }
        apps.append(app)
        return nil
    }

    /// No apps: everywhere.
    mutating func setApps(_ ids: Set<String>, for key: DictionaryKey) -> DictionaryChangeError? {
        guard ids.allSatisfy({ app(id: $0) != nil }) else { return .unknownApp }
        limits[key] = ids.isEmpty ? nil : ids
        return nil
    }

    /// Forgets the app. Returns the words whose only app it was, which the caller removes: they must never become
    /// global. nil if it was not known.
    mutating func removeApp(id: String) -> [DictionaryKey]? {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return nil }
        apps.remove(at: index)
        var orphaned: [DictionaryKey] = []
        for (key, ids) in limits where ids.contains(id) {
            let remaining = ids.subtracting([id])
            limits[key] = remaining.isEmpty ? nil : remaining
            if remaining.isEmpty { orphaned.append(key) }
        }
        return orphaned
    }
}

/// The whole dictionary: entries, the global ignore list, and the apps words are limited to. Edits keep every limited
/// word an entry.
public struct ScopedDictionary: Equatable, Sendable {
    public internal(set) var dictionary = CustomDictionary()
    public internal(set) var scopes = DictionaryAppScopes()

    public init() {}

    init(dictionary: CustomDictionary, scopes: DictionaryAppScopes) {
        self.dictionary = dictionary
        self.scopes = scopes
    }

    /// Whether the entry `key` is boosted in a dictation into `appID` (nil: no app).
    public func applies(_ key: DictionaryKey, in appID: String?) -> Bool {
        guard dictionary.contains(key) else { return false }
        let ids = scopes.apps(for: key)
        return ids.isEmpty || appID.map(ids.contains) == true
    }

    /// The entries a dictation into `appID` decodes with, in entry order. The app is kept only if it has limited
    /// words, so other apps share the global graph (DESIGN §3.6).
    public func decodingWords(for appID: String?) -> (entries: [DictionaryEntry], appID: String?) {
        let entries = dictionary.entries.filter { applies($0.key, in: appID) }
        guard let appID, scopes.wordCount(in: appID) > 0 else { return (entries, nil) }
        return (entries, appID)
    }
}

/// Every change to the dictionary goes through here (DESIGN §3.3, §3.6). Each call returns the proposed state.
struct ScopedDictionaryEditor: Sendable {
    let editor: DictionaryEditor

    init(encoder: BPEEncoder?) { editor = DictionaryEditor(encoder: encoder) }

    var canEdit: Bool { editor.canEdit }

    /// Adds, or edits `original`, limited to `apps` (none: everywhere). `soundsLike` as `DictionaryEditor.saving`.
    func saving(text: String, strength: Float, soundsLike: [String]? = nil, apps: Set<String>,
                replacing original: DictionaryKey?,
                in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError> {
        switch editor.saving(text: text, strength: strength, soundsLike: soundsLike, replacing: original,
                             in: current.dictionary) {
        case .failure(let error):
            return .failure(error)
        case .success(let dictionary):
            var updated = ScopedDictionary(dictionary: dictionary, scopes: current.scopes)
            if let original { _ = updated.scopes.setApps([], for: original) }
            let key = DictionaryKey(DictionaryValidation.normalize(text))
            if let error = updated.scopes.setApps(apps, for: key) { return .failure(error) }
            return .success(updated)
        }
    }

    /// nil when there is nothing to remove.
    func removing(_ key: DictionaryKey,
                  in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError>? {
        switch editor.removing(key, in: current.dictionary) {
        case nil: return nil
        case .failure(let error)?: return .failure(error)
        case .success(let dictionary)?:
            var updated = ScopedDictionary(dictionary: dictionary, scopes: current.scopes)
            _ = updated.scopes.setApps([], for: key)
            return .success(updated)
        }
    }

    /// A suggestion's Add to <App> (`app`) or Add everywhere (nil). An existing word keeps its text and spellings, takes
    /// the higher strength, and gains the app unless it already applies everywhere.
    func adding(_ word: String, strength: Float, to app: DictionaryApp?,
                in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError> {
        guard canEdit else { return .failure(.noVocabulary) }
        var base = current
        if let app, let error = base.scopes.register(app) { return .failure(error) }
        let key = DictionaryKey(DictionaryValidation.normalize(word))
        let existing = base.dictionary.entries.first { $0.key == key }
        let saved = saving(text: existing?.text ?? word, strength: max(existing?.strength ?? strength, strength),
                           apps: [], replacing: existing?.key, in: base)
        guard case .success(var updated) = saved else { return saved }
        let previous = base.scopes.apps(for: key)
        let apps: Set<String>
        if let app {
            apps = existing != nil && previous.isEmpty ? [] : previous.union([app.id])
        } else {
            apps = []
        }
        if let error = updated.scopes.setApps(apps, for: key) { return .failure(error) }
        return .success(updated)
    }

    /// Adds an app, or updates a known app's name.
    func registering(_ app: DictionaryApp,
                     in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError> {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = current
        if let error = updated.scopes.register(app) { return .failure(error) }
        return .success(updated)
    }

    /// Forgets the app and removes the words only it had. nil if it is not known.
    func removingApp(_ id: String,
                     in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = current
        guard let orphaned = updated.scopes.removeApp(id: id) else { return nil }
        for key in orphaned { updated.dictionary.remove(key) }
        return .success(updated)
    }

    func ignoring(_ key: DictionaryKey,
                  in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError> {
        switch editor.ignoring(key, in: current.dictionary) {
        case .failure(let error): return .failure(error)
        case .success(let dictionary): return .success(ScopedDictionary(dictionary: dictionary, scopes: current.scopes))
        }
    }

    /// nil when the key is not ignored.
    func unignoring(_ key: DictionaryKey,
                    in current: ScopedDictionary) -> Result<ScopedDictionary, DictionaryChangeError>? {
        switch editor.unignoring(key, in: current.dictionary) {
        case nil: return nil
        case .failure(let error)?: return .failure(error)
        case .success(let dictionary)?:
            return .success(ScopedDictionary(dictionary: dictionary, scopes: current.scopes))
        }
    }
}

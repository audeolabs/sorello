import Foundation

// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// Why a dictionary change was refused (DESIGN §3.3 and §3.6). Messages never quote a word or an app.
public enum DictionaryChangeError: Error, Equatable, Sendable {
    /// No speech-model vocabulary: the encodability check of §1.1 cannot run, so nothing may change (an unchecked
    /// entry could make the file unreadable once the vocabulary is back).
    case noVocabulary
    case invalid(DictionaryEntryError)
    /// The dictionary holds 1000 entries.
    case full
    /// The ignore list, which has its own capacity.
    case ignoreFull
    case invalidKey
    /// 32 apps are known already.
    case appsFull
    /// A word was limited to an app that is not known.
    case unknownApp
    /// The change could not be written to disk, so it was not made.
    case notSaved

    public var message: String {
        switch self {
        case .noVocabulary:
            return String(localized: "The dictionary needs the speech model, which isn’t available.")
        case .invalid(let error): return error.message
        case .full:
            return String(localized: "The dictionary is full (\(DictionaryValidation.capacity) entries).")
        case .ignoreFull:
            return String(localized: "The ignored-words list is full (\(DictionaryValidation.ignoreCapacity) words).")
        case .invalidKey: return DictionaryEntryError.unencodable.message
        case .appsFull:
            return String(localized: "Words can be kept for at most \(DictionaryAppScopes.appCapacity) apps.")
        case .unknownApp: return String(localized: "Add the app before limiting words to it.")
        case .notSaved: return String(localized: "The dictionary couldn’t be saved.")
        }
    }
}

/// Every change to the entries and the ignore list is made here. Each call returns the proposed state; the store
/// writes it before publishing it. It is public, with `CustomDictionary.init(entries:ignore:)`, for an app that keeps
/// its dictionary in a store of its own, as the iPhone app does (ARCHITECTURE.md, section 13): that app edits and
/// rebuilds its dictionary by these rules and has no copy of them.
public struct DictionaryEditor: Sendable {
    let encoder: BPEEncoder?

    /// An editor that checks entries against the speech model's vocabulary. Without one (nil) it changes nothing.
    public init(encoder: BPEEncoder?) {
        self.encoder = encoder
    }

    /// Whether anything can be changed: only with a vocabulary.
    public var canEdit: Bool { encoder != nil }

    /// Adds, or edits the entry `original` (its key may change).
    public func saving(text: String, strength: Float, replacing original: DictionaryKey?,
                in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryChangeError> {
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
    public func removing(_ key: DictionaryKey,
                  in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryChangeError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        return updated.remove(key) ? .success(updated) : nil
    }

    /// Adds `key` to the ignore list. Ignoring a key that is ignored already changes nothing.
    public func ignoring(_ key: DictionaryKey,
                  in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryChangeError> {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        switch updated.addIgnore(key) {
        case .full?: return .failure(.ignoreFull)
        case .invalidKey?: return .failure(.invalidKey)
        case nil: return .success(updated)
        }
    }

    /// nil when the key is not ignored.
    public func unignoring(_ key: DictionaryKey,
                    in dictionary: CustomDictionary) -> Result<CustomDictionary, DictionaryChangeError>? {
        guard canEdit else { return .failure(.noVocabulary) }
        var updated = dictionary
        return updated.removeIgnore(key) ? .success(updated) : nil
    }
}

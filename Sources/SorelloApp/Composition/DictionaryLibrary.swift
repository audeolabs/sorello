import DictationCore
import DictionaryKit
import Foundation
import Observation

/// The one way the app changes the dictionary (docs/dictionary/DESIGN.md, section 3.3). It passes each change to
/// `DictionaryStore`, which validates, writes and publishes it, then shows the published dictionary to the windows
/// and tells the correction coordinator, which stops its work and withdraws a suggestion after every change.
///
/// The store itself is not observable: its values are read through a lock by the speech engine on its own thread.
/// This keeps a main-actor copy that changes only when the store's revision does.
@MainActor
@Observable
final class DictionaryLibrary {
    /// The store the engine reads its snapshots from.
    @ObservationIgnored let store: DictionaryStore
    /// The speech model's vocabulary, for validating what is typed; nil without the model.
    @ObservationIgnored let encoder: BPEEncoder?
    /// Called after every published change.
    @ObservationIgnored var didChange: (@MainActor () -> Void)?

    /// The whole dictionary as last published.
    private(set) var dictionary: ScopedDictionary
    /// The store's revision for `dictionary`.
    private(set) var revision: UInt64
    /// Whether changes can be made: the vocabulary is loaded and the file may be written.
    private(set) var canEdit: Bool

    init(store: DictionaryStore, encoder: BPEEncoder?) {
        self.store = store
        self.encoder = encoder
        dictionary = store.dictionary
        revision = store.revision
        canEdit = store.canEdit
    }

    /// Whether another word fits.
    var hasRoom: Bool { dictionary.dictionary.entries.count < DictionaryValidation.capacity }

    /// The keys never offered as suggestions.
    var ignoredKeys: Set<DictionaryKey> { Set(dictionary.dictionary.ignore) }

    /// Adds a word, or edits the entry `original`, limited to `apps` (none: everywhere).
    func save(text: String, strength: Float, apps: Set<String>, replacing original: DictionaryKey?)
    throws(DictionaryChangeError) {
        defer { publish() }
        try store.save(text: text, strength: strength, apps: apps, replacing: original)
    }

    /// Removes a word and its app limits.
    func remove(_ key: DictionaryKey) throws(DictionaryChangeError) {
        defer { publish() }
        try store.remove(key)
    }

    /// A suggestion's Add: limited to `app`, or everywhere with nil.
    func add(_ word: String, strength: Float, to app: DictionaryApp?) throws(DictionaryChangeError) {
        defer { publish() }
        try store.add(word, strength: strength, to: app)
    }

    /// Makes an app known, so words can be limited to it.
    func register(_ app: DictionaryApp) throws(DictionaryChangeError) {
        defer { publish() }
        try store.register(app)
    }

    /// A suggestion's Don't Suggest.
    func ignore(_ key: DictionaryKey) throws(DictionaryChangeError) {
        defer { publish() }
        try store.ignore(key)
    }

    /// Lets a word be suggested again.
    func unignore(_ key: DictionaryKey) throws(DictionaryChangeError) {
        defer { publish() }
        try store.unignore(key)
    }

    /// Shows what the store published. A refused change can still have published one: a file that could not be
    /// opened before is read again by the next change.
    private func publish() {
        canEdit = store.canEdit
        let published = store.revision
        guard published != revision else { return }
        revision = published
        dictionary = store.dictionary
        didChange?()
    }
}

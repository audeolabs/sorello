import Foundation

/// The emoji recents as the keyboard keeps them (ARCHITECTURE.md, "Emoji panel"): in its own `UserDefaults`, which needs
/// no Full Access. One per keyboard instance, shared by the panel and emoji search, so an emoji chosen either way moves
/// to the front for both. Only catalog emoji are kept (`EmojiRecents`); nothing else about typing is stored.
final class EmojiRecentsStore {
    /// Kept: people's recents are saved under it (ARCHITECTURE.md, "Identifiers").
    static let key = "emojiRecents"

    private let defaults: UserDefaults
    private(set) var recents: EmojiRecents

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = EmojiRecents(stored: defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// An emoji was typed from the panel or chosen by search: it moves to the front, and is saved.
    func use(_ emoji: String) {
        recents.use(emoji)
        defaults.set(recents.emoji, forKey: Self.key)
    }
}

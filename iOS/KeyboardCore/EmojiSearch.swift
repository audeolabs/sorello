import Foundation

/// What emoji search needs from the keyboard (ARCHITECTURE.md, "Emoji search"): the recents, which lead their group of
/// matches. The keyboard gives none where the search does not run (`EmojiSearch.runs`).
struct EmojiSearchSetup: Equatable, Sendable {
    var recents: [String] = []
}

/// Emoji search, pure (ARCHITECTURE.md, "Emoji search"): the query a `:` and letters the keyboard typed make, and the
/// catalog's emoji that match it, best first, from `EmojiNames` (Unicode's CLDR annotations). `KeyboardEditor` shows them
/// in the candidate strip and puts a tapped one in place of the query.
enum EmojiSearch {
    /// The most matches the strip offers.
    static let limit = 5
    /// The fewest letters that make a query: `:p`, `:D` and `:o` are faces.
    static let minimumLetters = 2
    /// Besides whitespace and the field's start, what a query's `:` may follow.
    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}"]

    /// Everyday queries whose expected emoji Unicode's data does not put first (`:heart` would offer 💖 "sparkling
    /// heart" before ❤️). Each is a catalog emoji, and matches its query whatever its names say. Made from the misses of
    /// an earlier run of `EmojiSearchEvaluation`.
    static let preferred: [String: String] = [
        "heart": "❤️", "love": "❤️", "smile": "😄", "laugh": "😂", "lol": "😂", "haha": "😂", "wave": "👋",
        "think": "🤔", "cake": "🎂", "moon": "🌙", "kiss": "😘", "plane": "✈️", "car": "🚗", "book": "📖",
        "stop": "🛑", "music": "🎵", "hug": "🤗", "poop": "💩", "idea": "💡", "flower": "🌸", "point": "👉",
        "sick": "🤢", "sleep": "😴", "devil": "😈", "angel": "😇", "ball": "⚽", "snow": "❄️", "lightning": "⚡",
        "yes": "👍",
    ]

    /// Whether emoji search runs in a field: not in URL and email fields (which have no emoji key) or secure ones.
    static func runs(in field: KeyboardField, secureTextEntry: Bool) -> Bool {
        !secureTextEntry && field != .url && field != .email
    }

    /// The query in `record`, the keyboard's own word, with `before` the editor's text before the caret: its letters,
    /// lowercased and without accents, when it starts a search (`startsSearch`) and holds at least `minimumLetters`. Nil
    /// otherwise.
    static func query(record: WordTapRecord, before: String) -> String? {
        guard record.entries.count >= minimumLetters, startsSearch(record: record, before: before) else { return nil }
        return fold(record.text)
    }

    /// Whether `record` is letters (one or more) right after a `:` the keyboard typed that stands at the field's start or
    /// after whitespace or an opener: a query, or the start of one. Autocorrect leaves such letters alone.
    static func startsSearch(record: WordTapRecord, before: String) -> Bool {
        guard record.owned, record.boundary == ":", !record.entries.isEmpty,
              record.entries.allSatisfy({ $0.character.isLetter }) else { return false }
        let typed = ":" + record.text
        guard before.hasSuffix(typed) else { return false }
        guard let previous = before.dropLast(typed.count).last else { return true }
        return previous.isWhitespace || openers.contains(previous)
    }

    /// Lowercase, without accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// The catalog's emoji matching `query`, best first, at most `limit`: whole-word matches (a word of the name or of a
    /// keyword is the query, or the name without its spaces is), then prefix matches (one starts with it). Within each,
    /// the recents first (newest first), then the preferred emoji, then by where the query is found, then fewer words in
    /// the name, then the catalog's order.
    static func matches(for query: String, recents: [String] = [], limit: Int = limit) -> [String] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let recent = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var wholePreferred: [String: Int] = [:]
        if let emoji = preferred[query] { wholePreferred[emoji] = 0 }
        var prefixPreferred: [String: Int] = [:]
        for key in preferred.keys.filter({ $0.hasPrefix(query) && $0 != query })
            .sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            if let emoji = preferred[key], prefixPreferred[emoji] == nil { prefixPreferred[emoji] = prefixPreferred.count }
        }
        /// Group (0 whole, 1 prefix), recency, preference, where it was found, words in the name, catalog order.
        typealias Rank = (group: Int, recent: Int, preferred: Int, found: Int, words: Int, index: Int)
        var ranked: [(rank: Rank, emoji: String)] = []
        for (index, entry) in Entry.all.enumerated() {
            let unranked = Int.max
            let words = entry.name.count
            if let found = entry.wholeMatch(query) ?? (wholePreferred[entry.emoji] != nil ? 0 : nil) {
                ranked.append(((0, recent[entry.emoji] ?? unranked, wholePreferred[entry.emoji] ?? unranked, found, words, index),
                               entry.emoji))
            } else if let found = entry.prefixMatch(query) ?? (prefixPreferred[entry.emoji] != nil ? 0 : nil) {
                ranked.append(((1, recent[entry.emoji] ?? unranked, prefixPreferred[entry.emoji] ?? unranked, found, words, index),
                               entry.emoji))
            }
        }
        ranked.sort { $0.rank < $1.rank }
        return ranked.prefix(limit).map(\.emoji)
    }

    /// The strip for the query in `record` (`before`: the editor's text before the caret), as a typing strip the editor
    /// shows and applies like autocorrect's: the matches, nothing marked; a choice deletes the `:` and the letters. Nil
    /// for no query, no setup (the search does not run here) or no match.
    static func typingStrip(before: String, record: WordTapRecord, setup: EmojiSearchSetup?) -> WordAutocorrect.Typing? {
        guard let setup, let query = query(record: record, before: before) else { return nil }
        let found = matches(for: query, recents: setup.recents)
        guard !found.isEmpty else { return nil }
        return WordAutocorrect.Typing(strip: SwipeStrip(candidates: found, inserted: 0,
                                                        live: SwipeStrip.Live(quoted: nil, marked: nil), emoji: true),
                                      typed: record.text, word: query, deletes: record.entries.count + 1)
    }

    /// One catalog emoji's words, parsed from `EmojiNames` on the first search.
    struct Entry {
        var emoji: String
        /// The words of its English name, in order.
        var name: [String]
        /// The name without its spaces and punctuation.
        var joined: String
        /// The other words of its keywords.
        var keywords: [String]

        static let all: [Entry] = EmojiNames.packed.split(separator: "\n").map { line in
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            let name = fields[1].split(separator: " ").map(String.init)
            return Entry(emoji: String(fields[0]), name: name, joined: name.joined(),
                         keywords: fields[2].split(separator: " ").map(String.init))
        }

        /// 0: the name without its spaces is the query; 1: a word of the name is; 2: a word of a keyword is.
        func wholeMatch(_ query: String) -> Int? {
            if joined == query { return 0 }
            if name.contains(query) { return 1 }
            if keywords.contains(query) { return 2 }
            return nil
        }

        /// 0: the name without its spaces, or a word of it, starts with the query; 1: a word of a keyword does.
        func prefixMatch(_ query: String) -> Int? {
            if joined.hasPrefix(query) || name.contains(where: { $0.hasPrefix(query) }) { return 0 }
            if keywords.contains(where: { $0.hasPrefix(query) }) { return 1 }
            return nil
        }
    }
}

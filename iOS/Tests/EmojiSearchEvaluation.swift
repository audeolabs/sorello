import Foundation

/// Emoji search's evaluation (ARCHITECTURE.md, "Emoji search", Evaluation): invented everyday queries, each with the emoji
/// that would be a right first answer, run through `EmojiSearch.matches` with no recents. Guards how often the first match,
/// and one of the first three, is right. `EmojiSearch.preferred` was made from an earlier run's misses.
enum EmojiSearchEvaluation {
    static var tests: [TestCase] {
        [("theFirstMatchIsUsuallyRight", testTheFirstMatchIsUsuallyRight)]
    }

    /// A query and the emoji that would be a right first answer, space-separated.
    static let cases: [(query: String, right: String)] = [
        ("heart", "❤️"), ("love", "❤️ 🥰 😍 💕"), ("smile", "😀 😃 😄 🙂 😊 ☺️ 😁"), ("happy", "😀 😃 😄 😊 🙂 😁"),
        ("sad", "😢 😞 ☹️ 😔 🙁 😥"), ("cry", "😢 😭"), ("laugh", "😂 😆 🤣 😄"), ("lol", "😂 🤣 😆"), ("joy", "😂"), ("fire", "🔥"),
        ("ok", "👌 🆗"), ("thumbs", "👍"), ("clap", "👏"), ("pray", "🙏"), ("wave", "👋"), ("eyes", "👀"), ("think", "🤔"),
        ("thinking", "🤔"), ("skull", "💀"), ("party", "🎉 🥳"), ("cake", "🎂 🍰"), ("sun", "☀️ 🌞"), ("star", "⭐ 🌟"),
        ("moon", "🌙 🌕"), ("check", "✅ ✔️"), ("cat", "🐈 🐱"), ("dog", "🐶 🐕"), ("kiss", "😘 💋"), ("cool", "😎 🆒"),
        ("plane", "✈️"), ("car", "🚗"), ("phone", "📱"), ("money", "💰 💵 🤑"), ("book", "📖 📚"), ("stop", "🛑"),
        ("music", "🎵 🎶"), ("hug", "🤗 🫂"), ("beer", "🍺 🍻"), ("coffee", "☕"), ("pizza", "🍕"), ("rocket", "🚀"),
        ("poop", "💩"), ("hundred", "💯"), ("wink", "😉"), ("angry", "😠 😡"), ("shrug", "🤷"), ("facepalm", "🤦"),
        ("muscle", "💪"), ("flex", "💪"), ("gift", "🎁"), ("ghost", "👻"), ("rainbow", "🌈"), ("house", "🏠"),
        ("idea", "💡"), ("warning", "⚠️"), ("sparkles", "✨"), ("tada", "🎉"), ("sob", "😭"), ("grin", "😁 😀"),
        ("blush", "😊"), ("sweat", "😅 💦"), ("tree", "🌳 🌲"), ("flower", "🌸 💐 🌷 🌹"), ("rose", "🌹"), ("baby", "👶"),
        ("eye", "👁️ 👀"), ("hand", "✋ 👋"), ("point", "👉 ☝️"), ("hot", "🥵 🔥"), ("cold", "🥶"), ("sick", "🤢 🤒"),
        ("sleep", "😴"), ("dead", "💀"), ("wow", "😮 🤩"), ("scream", "😱"), ("devil", "😈"), ("angel", "😇"),
        ("crown", "👑"), ("gem", "💎"), ("trophy", "🏆"), ("soccer", "⚽"), ("ball", "⚽ 🏀"), ("apple", "🍎"),
        ("eggplant", "🍆"), ("peach", "🍑"), ("taco", "🌮"), ("wine", "🍷"), ("cheers", "🥂 🍻"), ("snow", "❄️ ☃️"),
        ("rain", "🌧️ ☔"), ("earth", "🌍 🌎 🌏"), ("lightning", "⚡"), ("bomb", "💣"), ("lock", "🔒"), ("key", "🔑"),
        ("bell", "🔔"), ("calendar", "📅 📆"), ("clock", "🕐 ⏰"), ("mail", "📧 ✉️"), ("pen", "🖊️"), ("dollar", "💵"),
        ("flag", "🏁 🚩"), ("no", "🚫 🙅 ❌"), ("yes", "👍 ✅"), ("nerd", "🤓"), ("zany", "🤪"), ("unicorn", "🦄"),
        ("monkey", "🐒 🐵"), ("horse", "🐎 🐴"), ("pig", "🐖 🐷"), ("fish", "🐟"), ("bird", "🐦"), ("bee", "🐝"),
        ("bug", "🐛"), ("snake", "🐍"), ("frog", "🐸"), ("bear", "🐻"), ("panda", "🐼"),
    ]

    static func measure() -> (first: Int, three: Int, misses: [String]) {
        var first = 0, three = 0
        var misses: [String] = []
        for item in cases {
            let right = Set(item.right.split(separator: " ").map(String.init))
            let found = EmojiSearch.matches(for: item.query)
            if let best = found.first, right.contains(best) { first += 1 } else { misses.append(item.query) }
            if found.prefix(3).contains(where: right.contains) { three += 1 }
        }
        return (first, three, misses)
    }

    private static func testTheFirstMatchIsUsuallyRight() {
        TestSupport.expectEqual(cases.count, 118)
        let catalog = Set(EmojiCatalog.categories.flatMap(\.emoji))
        for item in cases {
            for emoji in item.right.split(separator: " ") {
                TestSupport.expect(catalog.contains(String(emoji)), "\(item.query): \(emoji) is no catalog emoji")
            }
        }
        let measured = measure()
        TestSupport.expect(measured.first >= 117, "first \(measured.first) < 117, missed \(measured.misses)")
        TestSupport.expect(measured.three >= 117, "three \(measured.three) < 117")
    }
}

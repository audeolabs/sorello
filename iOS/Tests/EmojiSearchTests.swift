import Foundation

/// Emoji search (ARCHITECTURE.md, "Emoji search"): the query a `:` and letters make, the emoji that match it and their
/// order, where it runs, the strip it shows, a tapped emoji's place and space, autocorrect leaving the query alone, and the
/// recents it shares with the panel. Every text is invented.
enum EmojiSearchTests {
    static var tests: [TestCase] {
        [
            ("theQueryIsLettersAfterAColonTheKeyboardTyped", testTheQueryIsLettersAfterAColonTheKeyboardTyped),
            ("theColonMustStartAWord", testTheColonMustStartAWord),
            ("theQueryNeedsTwoLettersAndNothingElse", testTheQueryNeedsTwoLettersAndNothingElse),
            ("theQueryIgnoresCaseAndAccents", testTheQueryIgnoresCaseAndAccents),
            ("aWholeNameMatchesWithoutItsSpaces", testAWholeNameMatchesWithoutItsSpaces),
            ("wholeWordsComeBeforePrefixes", testWholeWordsComeBeforePrefixes),
            ("nameWordsComeBeforeKeywords", testNameWordsComeBeforeKeywords),
            ("tiesGoToShorterNamesThenTheCatalog", testTiesGoToShorterNamesThenTheCatalog),
            ("thePreferredEmojiLeads", testThePreferredEmojiLeads),
            ("thePreferredEmojiOfLongerQueriesLeadPrefixes", testThePreferredEmojiOfLongerQueriesLeadPrefixes),
            ("recentsLeadTheirGroup", testRecentsLeadTheirGroup),
            ("atMostFiveAndNoneForNoMatch", testAtMostFiveAndNoneForNoMatch),
            ("theDataCoversTheCatalog", testTheDataCoversTheCatalog),
            ("itRunsOutsideURLEmailAndSecureFields", testItRunsOutsideURLEmailAndSecureFields),
            ("typingAColonAndLettersShowsTheEmoji", testTypingAColonAndLettersShowsTheEmoji),
            ("itNeedsNoAutocorrect", testItNeedsNoAutocorrect),
            ("noSetupNoStrip", testNoSetupNoStrip),
            ("timesURLsLabelsAndFacesShowNothing", testTimesURLsLabelsAndFacesShowNothing),
            ("aTapPutsTheEmojiInWithOneSpace", testATapPutsTheEmojiInWithOneSpace),
            ("aSpaceAlreadyThereIsNotDoubled", testASpaceAlreadyThereIsNotDoubled),
            ("aTapNeedsTheQueryStillThere", testATapNeedsTheQueryStillThere),
            ("autocorrectLeavesTheQueryAlone", testAutocorrectLeavesTheQueryAlone),
            ("theSearchFollowsTheWord", testTheSearchFollowsTheWord),
            ("theRecentsOrderTheStrip", testTheRecentsOrderTheStrip),
            ("theRecentsStoreKeepsWhatWasChosen", testTheRecentsStoreKeepsWhatWasChosen),
        ]
    }

    /// `expectEqual` with what was being checked in its message.
    private static func equal<T: Equatable>(_ actual: T, _ expected: T, _ context: String, line: UInt = #line) {
        TestSupport.expect(actual == expected, "\(context): expected \(expected), got \(actual)", line: line)
    }

    // MARK: The query

    /// An owned record of `letters` typed right after a `:` the keyboard typed.
    private static func record(_ letters: String, boundary: Character? = ":") -> WordTapRecord {
        WordTapRecord(entries: letters.map { WordTapRecord.Entry(character: $0, point: nil) }, owned: true, boundary: boundary)
    }

    private static func testTheQueryIsLettersAfterAColonTheKeyboardTyped() {
        TestSupport.expectEqual(EmojiSearch.query(record: record("heart"), before: "so :heart"), "heart")
        // At the field's start.
        TestSupport.expectEqual(EmojiSearch.query(record: record("heart"), before: ":heart"), "heart")
        // A word after a space, or unowned letters, is no query.
        TestSupport.expectEqual(EmojiSearch.query(record: record("heart", boundary: " "), before: "so heart"), nil)
        let unowned = WordTapRecord(entries: record("heart").entries, owned: false, boundary: nil)
        TestSupport.expectEqual(EmojiSearch.query(record: unowned, before: "so :heart"), nil)
        // The editor's text must end with the colon and the letters.
        TestSupport.expectEqual(EmojiSearch.query(record: record("heart"), before: "so heart"), nil)
    }

    private static func testTheColonMustStartAWord() {
        for before in ["(:fire", "[:fire", "{:fire", "\":fire", "':fire", "\u{201C}:fire", "\u{2018}:fire", "a\n:fire",
                       "a\t:fire", "a :fire"] {
            equal(EmojiSearch.query(record: record("fire"), before: before), "fire", before)
        }
        // A label with no space, a URL's scheme and a time: the colon follows a letter or a digit.
        for before in ["Re:fire", "http:fire", "10:fire", "a.:fire", "a,:fire", "a::fire"] {
            equal(EmojiSearch.query(record: record("fire"), before: before), nil, before)
        }
    }

    private static func testTheQueryNeedsTwoLettersAndNothingElse() {
        TestSupport.expectEqual(EmojiSearch.minimumLetters, 2)
        // ":p", ":D" and ":o" are faces.
        for face in ["p", "D", "o"] {
            equal(EmojiSearch.query(record: record(face), before: ":" + face), nil, face)
        }
        TestSupport.expectEqual(EmojiSearch.query(record: record("ok"), before: ":ok"), "ok")
        // One letter starts a search (autocorrect leaves it alone) but is no query.
        TestSupport.expect(EmojiSearch.startsSearch(record: record("p"), before: "so :p"), "one letter")
        TestSupport.expect(!EmojiSearch.startsSearch(record: record("p"), before: "so:p"), "after a letter")
        TestSupport.expect(!EmojiSearch.startsSearch(record: record(""), before: "so :"), "no letter")
        // Apostrophes are word characters, not letters.
        TestSupport.expectEqual(EmojiSearch.query(record: record("it's"), before: ":it's"), nil)
        TestSupport.expectEqual(EmojiSearch.query(record: record("''"), before: ":''"), nil)
    }

    private static func testTheQueryIgnoresCaseAndAccents() {
        TestSupport.expectEqual(EmojiSearch.query(record: record("HEArt"), before: ":HEArt"), "heart")
        TestSupport.expectEqual(EmojiSearch.query(record: record("Piñata"), before: ":Piñata"), "pinata")
        TestSupport.expectEqual(EmojiSearch.matches(for: "pinata").first, "🪅")
    }

    // MARK: Matches and their order

    private static func testAWholeNameMatchesWithoutItsSpaces() {
        TestSupport.expectEqual(EmojiSearch.matches(for: "thumbsup").first, "👍")
        TestSupport.expectEqual(EmojiSearch.matches(for: "redheart").first, "❤️")
        TestSupport.expectEqual(EmojiSearch.matches(for: "facewithtearsofjoy"), ["😂"])
        // While it is typed, the name without its spaces is a prefix match too.
        TestSupport.expectEqual(EmojiSearch.matches(for: "thumbsu"), ["👍"])
    }

    private static func testWholeWordsComeBeforePrefixes() {
        // "hear" is a word of 🙉's and 👂's names, and the start of "heart".
        let hear = EmojiSearch.matches(for: "hear", limit: 200)
        let monkey = hear.firstIndex(of: "🙉")!, ear = hear.firstIndex(of: "👂")!, heart = hear.firstIndex(of: "❤️")!
        TestSupport.expect(monkey < heart && ear < heart, "\(hear.prefix(8))")
        // Each match once.
        TestSupport.expectEqual(Set(hear).count, hear.count)
    }

    private static func testNameWordsComeBeforeKeywords() {
        // 😂 "face with tears of joy" has "joy" in its name; 🥲 "smiling face with tear" only among its keywords.
        let joy = EmojiSearch.matches(for: "joy", limit: 200)
        TestSupport.expectEqual(joy.first, "😂")
        TestSupport.expect(joy.firstIndex(of: "😹")! < joy.firstIndex(of: "🥲")!, "\(joy)")
        // A prefix of a name word before a prefix of a keyword: "roc" starts 🚀 "rocket"'s name, and 🤘's keyword "rock".
        let roc = EmojiSearch.matches(for: "roc", limit: 200)
        TestSupport.expect(roc.firstIndex(of: "🚀")! < roc.firstIndex(of: "🤘")!, "\(roc)")
    }

    private static func testTiesGoToShorterNamesThenTheCatalog() {
        // Each has "cat" in its name: 🐈 "cat" (one word) first; 😺 "grinning cat" and 🐈‍⬛ "black cat" (two words) in the
        // catalog's order; 😸 "grinning cat with smiling eyes" (five) after both.
        let cat = EmojiSearch.matches(for: "cat", limit: 200)
        TestSupport.expectEqual(cat.first, "🐈")
        TestSupport.expect(cat.firstIndex(of: "😺")! < cat.firstIndex(of: "🐈‍⬛")!, "\(cat.prefix(6))")
        TestSupport.expect(cat.firstIndex(of: "🐈‍⬛")! < cat.firstIndex(of: "😸")!, "\(cat.prefix(6))")
    }

    private static func testThePreferredEmojiLeads() {
        // Unicode's data alone puts 💖 "sparkling heart" first.
        TestSupport.expectEqual(EmojiSearch.preferred["heart"], "❤️")
        TestSupport.expectEqual(EmojiSearch.matches(for: "heart").first, "❤️")
        TestSupport.expectEqual(EmojiSearch.matches(for: "car").first, "🚗")
        TestSupport.expectEqual(EmojiSearch.matches(for: "moon").first, "🌙")
        // Every preferred emoji is a catalog emoji, and matches its query.
        let catalog = Set(EmojiCatalog.categories.flatMap(\.emoji))
        for (query, emoji) in EmojiSearch.preferred {
            TestSupport.expect(catalog.contains(emoji), "\(query): \(emoji)")
            equal(EmojiSearch.matches(for: query).first, emoji, query)
        }
    }

    private static func testThePreferredEmojiOfLongerQueriesLeadPrefixes() {
        TestSupport.expectEqual(EmojiSearch.matches(for: "hea").first, "❤️")
        // "lol" is shorter than "love".
        TestSupport.expectEqual(Array(EmojiSearch.matches(for: "lo").prefix(2)), ["😂", "❤️"])
    }

    private static func testRecentsLeadTheirGroup() {
        // A recent whole-word match comes before the preferred emoji.
        TestSupport.expectEqual(Array(EmojiSearch.matches(for: "heart", recents: ["😂", "💙"]).prefix(2)), ["💙", "❤️"])
        // A recent that only starts with the query (🃏 "joker" has the keyword "card") stays behind every whole-word match
        // and leads the prefix matches: it takes the place of the first of them.
        let plain = EmojiSearch.matches(for: "car", limit: 200)
        let car = EmojiSearch.matches(for: "car", recents: ["🃏"], limit: 200)
        TestSupport.expectEqual(car.first, "🚗")
        TestSupport.expectEqual(car.firstIndex(of: "🃏"), plain.firstIndex(of: "🥕"))
        TestSupport.expect(plain.firstIndex(of: "🃏")! > plain.firstIndex(of: "🥕")!, "\(plain)")
        // A recent that does not match is not offered.
        TestSupport.expect(!EmojiSearch.matches(for: "heart", recents: ["🍕"], limit: 200).contains("🍕"), "pizza for heart")
    }

    private static func testAtMostFiveAndNoneForNoMatch() {
        TestSupport.expectEqual(EmojiSearch.limit, 5)
        TestSupport.expectEqual(EmojiSearch.matches(for: "heart").count, 5)
        TestSupport.expectEqual(EmojiSearch.matches(for: "zzqx"), [])
    }

    private static func testTheDataCoversTheCatalog() {
        let catalog = EmojiCatalog.categories.flatMap(\.emoji)
        let lines = EmojiNames.packed.split(separator: "\n")
        TestSupport.expectEqual(lines.map { String($0.split(separator: ";", omittingEmptySubsequences: false)[0]) }, catalog)
        for line in lines {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            equal(fields.count, 3, String(line))
            TestSupport.expect(!fields[1].isEmpty, "no name: \(line)")
            TestSupport.expect(fields[1...].joined(separator: " ").allSatisfy { $0 == " " || ("a" ... "z").contains($0)
                || ("0" ... "9").contains($0) }, "not folded: \(line)")
        }
    }

    private static func testItRunsOutsideURLEmailAndSecureFields() {
        TestSupport.expect(EmojiSearch.runs(in: .standard, secureTextEntry: false), "standard")
        TestSupport.expect(EmojiSearch.runs(in: .webSearch, secureTextEntry: false), "web search")
        TestSupport.expect(!EmojiSearch.runs(in: .url, secureTextEntry: false), "url")
        TestSupport.expect(!EmojiSearch.runs(in: .email, secureTextEntry: false), "email")
        TestSupport.expect(!EmojiSearch.runs(in: .standard, secureTextEntry: true), "secure")
    }

    // MARK: The editor

    private static func rig(_ text: String = "", recents: [String] = []) -> AutocorrectRig {
        let rig = AutocorrectRig(text, corrections: [:])
        rig.emojiRecents = recents
        rig.emojiSearchRuns = true
        return rig
    }

    private static func emojiStrip(_ query: String, recents: [String] = []) -> SwipeStrip {
        SwipeStrip(candidates: EmojiSearch.matches(for: query, recents: recents), inserted: 0,
                   live: SwipeStrip.Live(quoted: nil, marked: nil), emoji: true)
    }

    private static func testTypingAColonAndLettersShowsTheEmoji() {
        let rig = rig("see you")
        rig.press(.space)
        rig.press(.character(":"))
        // One letter: no search yet, and no word suggestions either.
        rig.corrector.predicted = ["h": WordPredictions(words: ["hi", "how"], isWord: false)]
        rig.tap("h")
        TestSupport.expectEqual(rig.strip, nil)
        TestSupport.expectEqual(rig.corrector.predictionCalls.count, 0)
        rig.tap("ea")
        TestSupport.expectEqual(rig.strip, emojiStrip("hea"))
        rig.tap("rt")
        TestSupport.expectEqual(rig.strip, emojiStrip("heart"))
        TestSupport.expectEqual(rig.strip?.candidates.first, "❤️")
        TestSupport.expectEqual(rig.strip?.emphasized, nil)
        // At a field's start too, and with no word suggestions from the corrector.
        let start = Self.rig()
        start.corrector.predicted = ["fire": WordPredictions(words: ["fired"], isWord: true)]
        start.press(.character(":"))
        start.tap("fire")
        TestSupport.expectEqual(start.strip, emojiStrip("fire"))
        TestSupport.expectEqual(start.corrector.predictionCalls.count, 0)
    }

    private static func testItNeedsNoAutocorrect() {
        // Autocorrect off (or no Full Access, or its model not loaded): the search still runs.
        let rig = rig()
        rig.enabled = false
        rig.press(.character(":"))
        rig.tap("fire")
        TestSupport.expectEqual(rig.strip, emojiStrip("fire"))
        // In a field that turns autocorrection off too.
        let literal = Self.rig()
        literal.autocorrectionDisabled = true
        literal.press(.character(":"))
        literal.tap("fire")
        TestSupport.expectEqual(literal.strip, emojiStrip("fire"))
    }

    private static func testNoSetupNoStrip() {
        // URL, email and secure fields: the keyboard gives no setup, and the query shows nothing.
        let rig = rig()
        rig.emojiSearchRuns = false
        rig.corrector.predicted = ["fire": WordPredictions(words: ["fired"], isWord: true)]
        rig.press(.character(":"))
        rig.tap("fire")
        TestSupport.expectEqual(rig.strip, nil)
    }

    private static func testTimesURLsLabelsAndFacesShowNothing() {
        for typed in ["10:30", "http://", "Re:hello", ":)", ":D", "a:fire"] {
            let rig = rig()
            for character in typed { rig.press(.character(String(character))) }
            TestSupport.expect(rig.strip?.emoji != true, "\(typed): \(String(describing: rig.strip))")
        }
    }

    private static func testATapPutsTheEmojiInWithOneSpace() {
        let rig = rig("love it")
        rig.press(.space)
        rig.press(.character(":"))
        rig.tap("heart")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "love it ❤️ ")
        TestSupport.expectEqual(rig.document.host.caret, "love it ❤️ ".utf16.count)
        TestSupport.expectEqual(rig.chosenEmoji, ["❤️"])
        TestSupport.expect(rig.strip?.emoji != true, "the search ends with the tap")
        // Punctuation typed next goes before the space.
        rig.press(.character("!"))
        TestSupport.expectEqual(rig.text, "love it ❤️! ")
        // Another candidate: the one tapped.
        let other = Self.rig()
        other.press(.character(":"))
        other.tap("fire")
        let second = other.strip!.candidates[1]
        other.choose(1)
        TestSupport.expectEqual(other.text, second + " ")
        TestSupport.expectEqual(other.chosenEmoji, [second])
        // Delete removes the space, then the emoji.
        other.heldDelete()
        TestSupport.expectEqual(other.text, second)
        other.heldDelete()
        TestSupport.expectEqual(other.text, "")
    }

    private static func testASpaceAlreadyThereIsNotDoubled() {
        let rig = AutocorrectRig(document: FakeDocument(FakeTextHost(text: "a b", caret: 1)), corrections: [:])
        rig.emojiSearchRuns = true
        rig.press(.space)
        rig.press(.character(":"))
        rig.tap("fire")
        rig.choose(0)
        TestSupport.expectEqual(rig.text, "a 🔥 b")
        TestSupport.expectEqual(rig.document.host.caret, "a 🔥".utf16.count)
        // A letter typed next gets a space of its own first.
        rig.tap("x")
        TestSupport.expectEqual(rig.text, "a 🔥 x b")
    }

    private static func testATapNeedsTheQueryStillThere() {
        // Another field before the tap: nothing is typed and the strip closes.
        let moved = rig()
        moved.press(.character(":"))
        moved.tap("fire")
        moved.document.switchField(to: FakeTextHost(text: ":fire"), id: UUID())
        moved.choose(0)
        TestSupport.expectEqual(moved.text, ":fire")
        TestSupport.expectEqual(moved.chosenEmoji, [])
        TestSupport.expect(moved.strip?.emoji != true, "the strip stays")
        // The host moved the caret after another copy of the query, unreported: it has other text after it.
        let moved2 = rig("x :fire x")
        moved2.press(.space)
        moved2.press(.character(":"))
        moved2.tap("fire")
        moved2.document.moveCaret(to: 7)
        moved2.choose(0)
        TestSupport.expectEqual(moved2.text, "x :fire x :fire")
        TestSupport.expectEqual(moved2.chosenEmoji, [])
        // The host typed before the colon, unreported: `Re:fire` is no query, so nothing is replaced.
        let label = rig()
        label.press(.character(":"))
        label.tap("fire")
        label.document.hostInserts("Re", at: 0)
        label.choose(0)
        TestSupport.expectEqual(label.text, "Re:fire")
        TestSupport.expectEqual(label.chosenEmoji, [])
        TestSupport.expect(label.strip?.emoji != true, "the strip stays")
    }

    private static func testAutocorrectLeavesTheQueryAlone() {
        for key in [KeyAction.space, .returnKey, .character("."), .character(":")] {
            let rig = AutocorrectRig("so", corrections: ["hart": "heart"])
            rig.emojiSearchRuns = true
            rig.press(.space)
            rig.press(.character(":"))
            rig.tap("hart")
            rig.press(key)
            let keyText = key == .space ? " " : key == .returnKey ? "\n" : key == .character(".") ? "." : ":"
            equal(rig.text, "so :hart" + keyText, "\(key)")
            equal(rig.corrector.calls.count, 0, "\(key)")
        }
        // Even where emoji search does not run (no setup), the letters after such a colon stay as typed.
        let off = AutocorrectRig("so", corrections: ["hart": "heart"])
        off.press(.space)
        off.press(.character(":"))
        off.tap("hart")
        off.press(.space)
        TestSupport.expectEqual(off.text, "so :hart ")
        // A word after a colon that starts nothing is corrected as before.
        let label = AutocorrectRig("so", corrections: ["hart": "heart"])
        label.emojiSearchRuns = true
        label.press(.space)
        label.tap("re")
        label.press(.character(":"))
        label.tap("hart")
        label.press(.space)
        TestSupport.expectEqual(label.text, "so re:heart ")
    }

    private static func testTheSearchFollowsTheWord() {
        // A Delete within the letters narrows it.
        let rig = rig()
        rig.press(.character(":"))
        rig.tap("fires")
        rig.heldDelete()
        TestSupport.expectEqual(rig.strip, emojiStrip("fire"))
        // Down to one letter: no strip; a letter more brings it back.
        rig.heldDelete(); rig.heldDelete(); rig.heldDelete()
        TestSupport.expectEqual(rig.strip, nil)
        rig.tap("i")
        TestSupport.expectEqual(rig.strip, emojiStrip("fi"))
        // Deleting back into it after its space brings it back.
        rig.tap("re")
        rig.press(.space)
        TestSupport.expect(rig.strip?.emoji != true, "the space ends the search")
        rig.heldDelete()
        TestSupport.expectEqual(rig.strip, emojiStrip("fire"))
        // Hiding keeps it, as it keeps the word: back in the same field, unchanged, the strip shows again.
        rig.hide()
        TestSupport.expectEqual(rig.strip, nil)
        rig.show()
        TestSupport.expectEqual(rig.strip, emojiStrip("fire"))
        // An outside edit (a caret move) ends it.
        rig.document.moveCaret(to: 0)
        rig.pump()
        TestSupport.expect(rig.strip?.emoji != true, "the caret moved")
    }

    private static func testTheRecentsOrderTheStrip() {
        let rig = rig(recents: ["💙"])
        rig.press(.character(":"))
        rig.tap("heart")
        TestSupport.expectEqual(rig.strip, emojiStrip("heart", recents: ["💙"]))
        TestSupport.expectEqual(rig.strip?.candidates.first, "💙")
    }

    private static func testTheRecentsStoreKeepsWhatWasChosen() {
        let name = "sorello-emoji-recents-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = EmojiRecentsStore(defaults: defaults)
        TestSupport.expectEqual(store.recents.emoji, [])
        store.use("🔥")
        store.use("❤️")
        TestSupport.expectEqual(store.recents.emoji, ["❤️", "🔥"])
        // Kept under the name people's recents were first saved under, and read back by the next keyboard.
        TestSupport.expectEqual(defaults.stringArray(forKey: "emojiRecents"), ["❤️", "🔥"])
        TestSupport.expectEqual(EmojiRecentsStore(defaults: defaults).recents.emoji, ["❤️", "🔥"])
    }
}

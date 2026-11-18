import Foundation

/// ARCHITECTURE.md, "Dictation corrections": the watch alone (`DictationCorrectionWatch`), then owned by `EditingCore`
/// and `KeyboardEditor` against a fake field. All text is invented.
enum DictationCorrectionTests {
    static var tests: [TestCase] {
        [
            ("constantsMatchContract", testConstantsMatchContract),
            ("anchorsPlaceTheDictationOnlyWithoutDoubt", testAnchorsPlaceTheDictationOnlyWithoutDoubt),
            ("checkedOnceTheTextIsQuiet", testCheckedOnceTheTextIsQuiet),
            ("theWatchEndsAtItsLifetime", testTheWatchEndsAtItsLifetime),
            ("onlyAWatchableDictationIsWatched", testOnlyAWatchableDictationIsWatched),
            ("anotherFieldOrASelectionOffersNothing", testAnotherFieldOrASelectionOffersNothing),
            ("aHugeContextIsNotChecked", testAHugeContextIsNotChecked),
            ("aFixInTheFieldIsOffered", testAFixInTheFieldIsOffered),
            ("wordsTypedAroundTheDictationAreDropped", testWordsTypedAroundTheDictationAreDropped),
            ("aRepeatedAnchorOffersNothing", testARepeatedAnchorOffersNothing),
            ("theWatchEndsAsTheContractSays", testTheWatchEndsAsTheContractSays),
            ("keysEndTheOfferAndRestartTheWait", testKeysEndTheOfferAndRestartTheWait),
        ]
    }

    private static let R = Fixture.requestID
    private static let S = Fixture.otherRequestID
    private static let field = Fixture.documentA

    private static func testConstantsMatchContract() {
        TestSupport.expectEqual(DictationCorrectionWatch.quietPeriod, 1.5)
        TestSupport.expectEqual(DictationCorrectionWatch.lifetime, 60)
        TestSupport.expectEqual(DictationCorrectionWatch.anchorLength, 24)
    }

    // MARK: The watch alone

    private static func locate(_ anchorBefore: String, _ anchorAfter: String, _ before: String, _ after: String) -> String? {
        DictationCorrectionWatch.locate(anchorBefore: anchorBefore, anchorAfter: anchorAfter, before: before, after: after)
    }

    private static func testAnchorsPlaceTheDictationOnlyWithoutDoubt() {
        let full = "Synthetic earlier words. "     // 25 characters: its last 24 are a full anchor
        let anchor = String(full.suffix(24))
        let tail = " And then something later"
        let after = String(tail.prefix(24))
        TestSupport.expectEqual(anchor.count, 24)
        TestSupport.expectEqual(locate(anchor, after, full + "call Xy", "lo now." + tail), "call Xylo now.")
        // A full anchor that occurs twice on its side places nothing.
        TestSupport.expectEqual(locate(anchor, after, full + full + "call Xy", "lo now." + tail), nil)
        TestSupport.expectEqual(locate(anchor, after, full + "call Xy", "lo now." + tail + tail), nil)
        // The dictation itself repeats the anchor.
        TestSupport.expectEqual(locate(anchor, after, full + anchor + "call", " now." + tail), nil)
        // A full anchor the proxy cut off places nothing.
        TestSupport.expectEqual(locate(anchor, after, "words. call Xy", "lo now." + tail), nil)
        TestSupport.expectEqual(locate(anchor, after, full + "call Xy", "lo now. And then"), nil)
        // A short anchor sits at the very edge of the field and nowhere else on its side.
        TestSupport.expectEqual(locate("Hi ", "", "Hi call Xylo", " now."), "call Xylo now.")
        TestSupport.expectEqual(locate("Hi ", "", "Oh Hi call Xylo", " now."), nil)
        TestSupport.expectEqual(locate("Hi ", "", "Hi Hi call Xylo", " now."), nil)
        TestSupport.expectEqual(locate("", "!", "call Xylo", " now!"), "call Xylo now")
        TestSupport.expectEqual(locate("", "!", "call Xylo", " now! Wow!"), nil)
        // Overlapping occurrences count.
        TestSupport.expectEqual(locate("", "!", "call Xylo", " now!!"), nil)
        // Empty anchors: the start of the text before the caret, the end of the text after it.
        TestSupport.expectEqual(locate("", "", "call Xy", "lo now."), "call Xylo now.")
        TestSupport.expectEqual(locate(String(repeating: "a", count: 24), "", String(repeating: "a", count: 25) + "b", ""), nil)
    }

    private static func watch(_ text: String = "call zylo now", before: String = "", after: String = "",
                              at time: TimeInterval = 10) -> DictationCorrectionWatch {
        var watch = DictationCorrectionWatch()
        watch.start(requestID: R, inserted: text, contextBefore: before, contextAfter: after, documentID: field, at: time)
        return watch
    }

    private static func testCheckedOnceTheTextIsQuiet() {
        var w = watch(" call zylo now ")
        TestSupport.expectEqual(w.watched?.text, "call zylo now")
        // Nothing is checked while nothing happened.
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: false, now: 20)
        TestSupport.expectEqual(w.offer, nil)
        w.activity(at: 21)
        TestSupport.expectEqual(w.checkDue, 22.5)
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: false, now: 22.49)
        TestSupport.expectEqual(w.offer, nil)
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: false, now: 22.5)
        TestSupport.expectEqual(w.offer, DictationCorrectionOffer(requestID: R, word: "Xylo", replacedWords: 1..<2))
        TestSupport.expectEqual(w.checkDue, nil)
        // Activity ends the offer; the next quiet check may offer another word.
        w.activity(at: 23)
        TestSupport.expectEqual(w.offer, nil)
        w.check(documentID: field, before: "call Xylo", after: " now", hasSelection: false, now: 24.5)
        TestSupport.expectEqual(w.offer?.word, "Xylo")
        // Unchanged text offers nothing.
        w.activity(at: 25)
        w.check(documentID: field, before: "call zylo now", after: "", hasSelection: false, now: 30)
        TestSupport.expectEqual(w.offer, nil)
        TestSupport.expect(w.isWatching, "the watch ended without a reason")
    }

    private static func testTheWatchEndsAtItsLifetime() {
        var w = watch()
        w.expire(now: 10 + 59.9)
        TestSupport.expect(w.isWatching, "ended early")
        w.activity(at: 69)
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: false, now: 70.5)
        TestSupport.expect(!w.isWatching && w.offer == nil, "checked past its lifetime")
        var back = watch()
        back.expire(now: 9)
        TestSupport.expect(!back.isWatching, "a clock that went back keeps the watch")
    }

    private static func testOnlyAWatchableDictationIsWatched() {
        TestSupport.expect(!watch("  \n ").isWatching, "an empty dictation")
        TestSupport.expect(!watch(Array(repeating: "word", count: 201).joined(separator: " ")).isWatching, "201 words")
        TestSupport.expect(watch(Array(repeating: "word", count: 200).joined(separator: " ")).isWatching, "200 words")
        TestSupport.expect(!watch(String(repeating: "é", count: 2049)).isWatching, "over 4096 bytes")
        var none = DictationCorrectionWatch()
        none.start(requestID: R, inserted: "call zylo", contextBefore: "", contextAfter: "", documentID: nil, at: 1)
        TestSupport.expect(!none.isWatching, "a field without an identity")
        let anchored = watch(before: String(repeating: "x", count: 30), after: String(repeating: "y", count: 30))
        TestSupport.expectEqual(anchored.watched?.anchorBefore.count, 24)
        TestSupport.expectEqual(anchored.watched?.anchorAfter.count, 24)
    }

    private static func testAnotherFieldOrASelectionOffersNothing() {
        var w = watch()
        w.activity(at: 11)
        w.check(documentID: Fixture.documentB, before: "call Xylo now", after: "", hasSelection: false, now: 13)
        TestSupport.expectEqual(w.offer, nil)
        w.activity(at: 13)
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: true, now: 15)
        TestSupport.expectEqual(w.offer, nil)
        TestSupport.expect(w.isWatching, "the watch should go on")
        w.activity(at: 15)
        w.check(documentID: field, before: "call Xylo now", after: "", hasSelection: false, now: 17)
        TestSupport.expectEqual(w.offer?.word, "Xylo")
    }

    /// The keyboard never aligns a dictation against an unbounded context: past `maxEditedWords` there is no offer.
    private static func testAHugeContextIsNotChecked() {
        let limit = DictationCorrectionWatch.maxEditedWords
        TestSupport.expectEqual(limit, 1000)
        func around(_ count: Int) -> String { " " + Array(repeating: "mine", count: count).joined(separator: " ") }
        var w = watch()
        w.activity(at: 11)
        w.check(documentID: field, before: "call Xylo now", after: around(limit - 3), hasSelection: false, now: 13)
        TestSupport.expectEqual(w.offer?.word, "Xylo")
        w.activity(at: 13)
        w.check(documentID: field, before: "call Xylo now", after: around(limit - 2), hasSelection: false, now: 15)
        TestSupport.expectEqual(w.offer, nil)
        TestSupport.expect(w.isWatching, "the watch should go on")
        // Counted as DictionaryKit splits: a combining mark after a space is a word, though Swift sees no space there.
        w.activity(at: 15)
        w.check(documentID: field, before: "call Xylo now", after: String(repeating: " \u{0301}", count: limit),
                hasSelection: false, now: 17)
        TestSupport.expectEqual(w.offer, nil)
    }

    // MARK: Owned by the editing core

    private static func core(_ text: String) -> (EditingCore, FakeDocument) {
        let document = FakeDocument(FakeTextHost(text: text, model: .whole))
        let core = EditingCore(document: document)
        core.reset()
        return (core, document)
    }

    /// The user replaces `old` with `new` the way typing does: a caret move the host reports, deletions and an
    /// insertion, each followed by the activity a key gives.
    private static func fix(_ core: EditingCore, _ document: FakeDocument, _ old: String, with new: String,
                            at time: TimeInterval) {
        let end = (document.text as NSString).range(of: old).upperBound
        document.host.moveCaret(to: end)
        _ = core.hostChanged(textChanged: false, now: time)
        for _ in 0..<old.utf16.count { document.deleteBackward() }
        core.userEdit()
        core.correctionActivity(now: time + 0.1)
        document.insertText(new)
        core.userEdit()
        core.correctionActivity(now: time + 0.2)
    }

    private static func testAFixInTheFieldIsOffered() {
        let (core, document) = core("Earlier synthetic note. ")
        core.insertDictation("Call zylo tomorrow.", now: 10, watching: R)
        fix(core, document, "zylo", with: "Xylo", at: 12)
        core.serviceCorrection(now: 13.6)
        TestSupport.expectEqual(core.correction.offer, nil)
        core.serviceCorrection(now: 13.7)
        TestSupport.expectEqual(core.correction.offer, DictationCorrectionOffer(requestID: R, word: "Xylo", replacedWords: 1..<2))
        // A casing fix counts; a sentence's first capital does not.
        let (casing, casingDocument) = self.core("")
        casing.insertDictation("we run nixos daily", now: 10, watching: R)
        fix(casing, casingDocument, "nixos", with: "NixOS", at: 11)
        casing.serviceCorrection(now: 13)
        TestSupport.expectEqual(casing.correction.offer?.word, "NixOS")
        let (capital, capitalDocument) = self.core("")
        capital.insertDictation("the plan works", now: 10, watching: R)
        fix(capital, capitalDocument, "the", with: "The", at: 11)
        capital.serviceCorrection(now: 13)
        TestSupport.expectEqual(capital.correction.offer, nil)
    }

    private static func testWordsTypedAroundTheDictationAreDropped() {
        let (core, document) = core("")
        core.insertDictation("Ship the cart now.", now: 10, watching: R)
        document.insertText(" Then a few more words of my own.")
        core.userEdit()
        fix(core, document, "cart", with: "chart", at: 11)
        document.host.moveCaret(to: document.text.utf16.count)
        _ = core.hostChanged(textChanged: false, now: 11.5)
        core.serviceCorrection(now: 13)
        TestSupport.expectEqual(core.correction.offer, DictationCorrectionOffer(requestID: R, word: "chart", replacedWords: 2..<3))
    }

    /// ARCHITECTURE.md, "Dictation corrections", Where the dictation is now: a repeated anchor places nothing.
    private static func testARepeatedAnchorOffersNothing() {
        let (core, document) = core("A repeated synthetic line. ")
        core.insertDictation("A repeated synthetic line. call zylo", now: 10, watching: R)
        fix(core, document, "zylo", with: "Xylo", at: 11)
        core.serviceCorrection(now: 13)
        TestSupport.expectEqual(core.correction.offer, nil)
        TestSupport.expect(core.correction.isWatching, "the watch should go on")
    }

    private static func testTheWatchEndsAsTheContractSays() {
        // Another field.
        var (core, document) = self.core("")
        core.insertDictation("call zylo now", now: 10, watching: R)
        document.documentID = Fixture.documentB
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 11), .newField)
        TestSupport.expect(!core.correction.isWatching, "another field kept the watch")
        // Hiding.
        (core, document) = self.core("")
        core.insertDictation("call zylo now", now: 10, watching: R)
        core.hide()
        TestSupport.expect(!core.correction.isWatching, "hiding kept the watch")
        // Its own Undo.
        (core, document) = self.core("")
        core.insertDictation("call zylo now", now: 10, watching: R)
        _ = core.beginUndo(now: 10.5)
        TestSupport.expect(!core.correction.isWatching, "its Undo kept the watch")
        // Another dictation's insertion, watched or not, and its start.
        (core, document) = self.core("")
        core.insertDictation("call zylo now", now: 10, watching: R)
        core.insertDictation(" and more", now: 11, watching: S)
        TestSupport.expectEqual(core.correction.watched?.requestID, S)
        core.insertDictation(" pressed\n", now: 12)
        TestSupport.expect(!core.correction.isWatching, "an unwatched insertion kept the old watch")
        core.insertDictation(" again", now: 13, watching: R)
        core.endCorrectionWatch()
        TestSupport.expect(!core.correction.isWatching, "a dictation's start kept the watch")
        // Text replacing a selection is not watched; an outside edit does not end a watch.
        (core, document) = self.core("Earlier words here")
        document.host.select(from: 0, length: 7)
        core.insertDictation("Later", now: 10, watching: R)
        TestSupport.expect(!core.correction.isWatching, "watched text that replaced a selection")
        (core, document) = self.core("")
        core.insertDictation("call zylo now", now: 10, watching: R)
        document.host.moveCaret(to: 0)
        TestSupport.expectEqual(core.hostChanged(textChanged: true, now: 11), .outside)
        TestSupport.expect(core.correction.isWatching, "an outside edit ended the watch")
    }

    // MARK: Through the editor

    /// Any key ends the offer and restarts the wait; the editor reports the offer as it comes and goes.
    private static func testKeysEndTheOfferAndRestartTheWait() {
        let document = FakeDocument(FakeTextHost(text: "", model: .whole))
        let trackpad = TrackpadController(host: document)
        let editor = KeyboardEditor(document: document, trackpad: trackpad)
        var reports = 0
        editor.onCorrectionOfferChanged = { reports += 1 }
        editor.reset(numeric: false)
        editor.insertDictation("call zylo now", now: 10, watching: R)
        TestSupport.expect(editor.isWatchingCorrection, "not watched")
        document.host.moveCaret(to: 9)
        editor.hostChanged(textChanged: false, now: 11)
        for _ in 0..<4 { editor.heldDelete(.character, field: document.documentID, now: 11.1) }
        for (index, letter) in ["X", "y", "l", "o"].enumerated() {
            editor.press(.character(letter), field: document.documentID, at: 11.2 + Double(index) * 0.1,
                         now: 11.2 + Double(index) * 0.1)
        }
        // The letters go in as the shift has them.
        let typed = String(document.text.dropFirst(5).prefix(4))
        TestSupport.expectEqual(typed.lowercased(), "xylo")
        editor.serviceCorrection(now: 12.9)
        TestSupport.expectEqual(editor.correctionOffer, nil)
        editor.serviceCorrection(now: 13.0)
        TestSupport.expectEqual(editor.correctionOffer?.word, typed)
        TestSupport.expectEqual(reports, 1)
        editor.press(.shift, field: document.documentID, at: 13.1, now: 13.1)
        TestSupport.expectEqual(editor.correctionOffer, nil)
        TestSupport.expectEqual(reports, 2)
        editor.serviceCorrection(now: 14.6)
        TestSupport.expectEqual(editor.correctionOffer?.word, typed)
        TestSupport.expectEqual(editor.acceptCorrectionOffer()?.word, typed)
        TestSupport.expect(!editor.isWatchingCorrection, "accepting kept the watch")
        TestSupport.expectEqual(reports, 4)
    }
}

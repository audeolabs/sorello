import Foundation

/// Search (ARCHITECTURE.md, "Notes", Library and search): every term must match a word start, folded for case,
/// diacritics and width; results are newest first with their matched ranges. Every text is invented.
enum NoteSearchTests {
    static var tests: [TestCase] {
        [
            ("everyTermMustMatchAWordStart", testEveryTermMustMatchAWordStart),
            ("matchingFoldsCaseDiacriticsAndWidth", testMatchingFoldsCaseDiacriticsAndWidth),
            ("wordsStartAfterPunctuation", testWordsStartAfterPunctuation),
            ("rangesAreSortedAndJoined", testRangesAreSortedAndJoined),
            ("resultsAreNewestFirst", testResultsAreNewestFirst),
            ("aQueryWithNoTermsMatchesEveryNote", testAQueryWithNoTermsMatchesEveryNote),
            ("theVaultSearchesWhatTheNotesShow", testTheVaultSearchesWhatTheNotesShow),
        ]
    }

    private static func note(_ text: String, modified seconds: TimeInterval = 0, id: Int = 1) -> Note {
        Note(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!, text: text, body: text,
             created: Fixture.now, modified: Fixture.now.addingTimeInterval(seconds), pendingRuns: [])
    }

    /// The texts each hit matched, per hit.
    private static func matched(_ query: String, in notes: [Note]) -> [[String]] {
        NoteSearch.search(query, in: notes).map { hit in hit.matches.map { String(hit.note.text[$0]) } }
    }

    private static func testEveryTermMustMatchAWordStart() {
        let notes = [note("The green invented bicycle")]
        TestSupport.expectEqual(matched("gre", in: notes), [["gre"]])
        TestSupport.expectEqual(matched("bicycle green", in: notes), [["green", "bicycle"]])
        TestSupport.expectEqual(matched("reen", in: notes), [])
        TestSupport.expectEqual(matched("green tricycle", in: notes), [])
        TestSupport.expectEqual(matched("green bicycles", in: notes), [])
        TestSupport.expectEqual(matched("green invented bi", in: notes), [["green", "invented", "bi"]])
    }

    private static func testMatchingFoldsCaseDiacriticsAndWidth() {
        let notes = [note("Café on the Straße, ÉTÉ")]
        TestSupport.expectEqual(matched("cafe", in: notes), [["Café"]])
        TestSupport.expectEqual(matched("CAFÉ", in: notes), [["Café"]])
        TestSupport.expectEqual(matched("strasse", in: notes), [["Straße"]])
        TestSupport.expectEqual(matched("stras", in: notes), [["Straß"]])   // a term ending inside ß covers it
        TestSupport.expectEqual(matched("ete", in: notes), [["ÉTÉ"]])
        TestSupport.expectEqual(matched("ｃａｆｅ", in: notes), [["Café"]])
        TestSupport.expectEqual(matched("cafe\u{301}", in: notes), [["Café"]])
    }

    private static func testWordsStartAfterPunctuation() {
        let notes = [note("Plan #garden-party (invented) at 10:30")]
        TestSupport.expectEqual(matched("garden", in: notes), [["garden"]])
        TestSupport.expectEqual(matched("#garden", in: notes), [["#garden"]])
        TestSupport.expectEqual(matched("party", in: notes), [["party"]])
        TestSupport.expectEqual(matched("invented", in: notes), [["invented"]])
        TestSupport.expectEqual(matched("(inv", in: notes), [["(inv"]])
        TestSupport.expectEqual(matched("30", in: notes), [["30"]])
        TestSupport.expectEqual(matched("arden", in: notes), [])
    }

    private static func testRangesAreSortedAndJoined() {
        let text = "invented ink, invented ideas"
        let hits = NoteSearch.search("ideas in", in: [note(text)])
        TestSupport.expectEqual(hits.count, 1)
        // "in" matches each word starting with it; "ideas" its word. Sorted by position, overlaps joined.
        TestSupport.expectEqual(hits[0].matches.map { String(text[$0]) }, ["in", "in", "in", "ideas"])
        TestSupport.expectEqual(hits[0].matches.map { text.distance(from: text.startIndex, to: $0.lowerBound) }, [0, 9, 14, 23])
        let overlapping = NoteSearch.search("inv invent", in: [note("invented")])
        TestSupport.expectEqual(overlapping[0].matches.map { String("invented"[$0]) }, ["invent"])
    }

    private static func testResultsAreNewestFirst() {
        let notes = [
            note("Invented walk, older", modified: 0, id: 1),
            note("Invented walk, newest", modified: 30, id: 2),
            note("Invented swim", modified: 60, id: 3),
            note("Invented walk, newer", modified: 10, id: 4),
        ]
        TestSupport.expectEqual(NoteSearch.search("walk", in: notes).map(\.note.text),
                                ["Invented walk, newest", "Invented walk, newer", "Invented walk, older"])
    }

    private static func testAQueryWithNoTermsMatchesEveryNote() {
        let notes = [note("Invented one", modified: 0, id: 1), note("Invented two", modified: 5, id: 2)]
        for query in ["", "   ", "\n"] {
            let hits = NoteSearch.search(query, in: notes)
            TestSupport.expectEqual(hits.map(\.note.text), ["Invented two", "Invented one"])
            TestSupport.expect(hits.allSatisfy { $0.matches.isEmpty }, "a query with no terms matched ranges")
        }
    }

    private static func testTheVaultSearchesWhatTheNotesShow() {
        let fixture = NoteFixture()
        try! fixture.vault.makeVault()
        fixture.record(["Invented recipe for lentil soup"])
        try! fixture.vault.mergePendingRuns()
        let writer = try! fixture.recorder.beginRun(.newNote)
        try! writer.append("An invented soup still recording")
        TestSupport.expectEqual(try! fixture.vault.searchIndex().search("soup").map(\.note.text).sorted(),
                                ["An invented soup still recording", "Invented recipe for lentil soup"])
        TestSupport.expectEqual(try! fixture.vault.searchIndex().search("lentil").map(\.note.text), ["Invented recipe for lentil soup"])
        writer.end()
    }
}

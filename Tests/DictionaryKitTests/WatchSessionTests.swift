import Foundation
import Testing
@testable import DictionaryKit
import Synchronization

/// One watched paste, driven by hand with invented times (DESIGN §3.5).
struct WatchSessionTests {
    let longAfter = "\nAn unrelated paragraph follows here, long enough to anchor."

    private func begin(_ reader: FakeTextFieldReader, pasted: String,
                       now: TimeInterval = 0) -> Result<CorrectionWatchSession, CorrectionDiscardReason> {
        guard let target = reader.captureFocusedTextField() else { return .failure(.focusChanged) }
        return CorrectionWatchSession.begin(reader: reader, target: target, pasted: pasted, correctionID: 7, now: now)
    }

    private func watching(_ reader: FakeTextFieldReader, pasted: String,
                          sourceLocation: SourceLocation = #_sourceLocation) throws -> CorrectionWatchSession {
        switch begin(reader, pasted: pasted) {
        case .success(let session): return session
        case .failure(let reason):
            Issue.record("Session must begin, got \(reason)", sourceLocation: sourceLocation)
            throw reason
        }
    }

    /// Polls once per second from `from` until something other than watching happens.
    private func pollUntilDone(_ session: CorrectionWatchSession, from: Int = 1, to: Int = 70,
                               each: (Int) -> Void = { _ in }) -> (CorrectionPollOutcome, Int) {
        for second in from...to {
            each(second)
            let outcome = session.poll(now: TimeInterval(second))
            if outcome != .watching { return (outcome, second) }
        }
        return (.watching, to)
    }

    private func edit(_ typed: String, _ edited: String) -> CorrectionEdit {
        CorrectionEdit(typed: typed, edited: edited, correctionID: 7)
    }

    @Test func spanTracking() throws {
        // Empty field: both edges are document sentinels.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("hello wrld. ")
            let session = try watching(reader, pasted: "hello wrld. ")
            #expect(session.record.before == .documentEdge && session.record.after == .documentEdge, "Sentinels")
            let (outcome, second) = pollUntilDone(session) { if $0 == 2 { reader.replace("wrld", with: "world") } }
            #expect(outcome == .settled(edit("hello wrld. ", "hello world. ")))
            #expect(second == 4, "Edited at 2, quiet for 1.5 s")
        }
        // Anchored on both sides, with an edit in the span only.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = try watching(reader, pasted: "ship the cart now. ")
            #expect(session.record.before == .text(Array("Intro line.\n".utf16)), "Short before context")
            #expect(session.record.after == .text(Array(longAfter.utf16.prefix(40))), "40-unit after context")
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }
            #expect(outcome == .settled(edit("ship the cart now. ", "ship the chart now. ")))
        }
        // Document start with an after anchor; document end with a before anchor.
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(session.record.before == .documentEdge && session.record.after != .documentEdge, "Document start")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0
                    == .settled(edit("cart", "chart")))
        }
        do {
            let prefix = String(repeating: "p", count: 50) + " "
            let reader = FakeTextFieldReader(prefix)
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(session.record.before == .text(Array(prefix.utf16.suffix(40))) && session.record.after == .documentEdge,
                    "Document end with a 40-unit before context")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0
                    == .settled(edit("cart", "chart")))
        }
        // Appended text: at the document end it joins the span; past an after anchor it does not.
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cooper netties")
            let session = try watching(reader, pasted: "cooper netties")
            let (outcome, _) = pollUntilDone(session) { second in
                if second == 1 { reader.replace("cooper netties", with: "Kubernetes") }
                if second == 2 { reader.append(" rocks") }
            }
            #expect(outcome == .settled(edit("cooper netties", "Kubernetes rocks")))
        }
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cooper netties")
            let session = try watching(reader, pasted: "cooper netties")
            let (outcome, _) = pollUntilDone(session) { second in
                if second == 1 { reader.replace("cooper netties", with: "Kubernetes") }
                if second == 2 { reader.append(" More typing at the end.") }
            }
            #expect(outcome == .settled(edit("cooper netties", "Kubernetes")))
        }
        // Repeated paragraphs: the pasted copy is tracked by offset, not by search.
        do {
            let paragraph = "alpha beta gamma.\n"
            let reader = FakeTextFieldReader(paragraph + paragraph + longAfter)
            reader.caret = paragraph.utf16.count * 2
            reader.paste(paragraph)
            let session = try watching(reader, pasted: paragraph)
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replaceLast("beta", with: "Beta-2") } }
            #expect(outcome == .settled(edit(paragraph, "alpha Beta-2 gamma.\n")))
        }
        // An after context that repeats inside the window is ambiguous.
        do {
            let repeated = String(repeating: "x", count: 50)
            let reader = FakeTextFieldReader(repeated + repeated)
            reader.caret = 0
            reader.paste("cart ")
            let session = try watching(reader, pasted: "cart ")
            #expect(pollUntilDone(session).0 == .discard(.endAmbiguous))
        }
        // Edits to either anchor discard; text inserted before the span moves it.
        for (change, reason): ((FakeTextFieldReader) -> Void, CorrectionDiscardReason) in [
            ({ $0.replace("Intro", with: "Outro") }, .startMoved),
            ({ $0.replace("unrelated", with: "other") }, .endNotFound),
            ({ $0.insert("Hi. ", at: 0) }, .startMoved),
            ({ $0.replace("line.\nship", with: "Ship") }, .startMoved),
        ] {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = try watching(reader, pasted: "ship the cart now. ")
            #expect(pollUntilDone(session) { if $0 == 1 { change(reader) } }.0 == .discard(reason))
        }
        // Selection replacement inside the span is an edit.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("ship the cart now. ")
            let session = try watching(reader, pasted: "ship the cart now. ")
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("the cart", with: "a chart") } }
            #expect(outcome == .settled(edit("ship the cart now. ", "ship a chart now. ")))
        }
        // Growth beyond 200 units discards, at the document end and before an anchor.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.append(String(repeating: "y", count: 201)) } }.0
                    == .discard(.spanChangedTooMuch))
        }
        do {
            let reader = FakeTextFieldReader(longAfter)
            reader.caret = 0
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.insert(String(repeating: "y", count: 201), at: 2) } }.0
                    == .discard(.endNotFound))
        }
        // Deleting the whole span ends the watch; with no edit before it, nothing is checked.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste("cart ")
            let session = try watching(reader, pasted: "cart ")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.replace("cart ", with: "") } }.0 == .discard(.spanRemoved))
        }
        // UTF-16 offsets: astral scalars and combining marks before the span.
        do {
            let prefix = "👍🏽 cafe\u{301} 𝔘nicode: "
            let reader = FakeTextFieldReader(prefix)
            reader.paste("naive plan")
            let session = try watching(reader, pasted: "naive plan")
            #expect(session.record.spanStart == prefix.utf16.count)
            let (outcome, _) = pollUntilDone(session) { if $0 == 1 { reader.replace("naive", with: "naïve 👍") } }
            #expect(outcome == .settled(edit("naive plan", "naïve 👍 plan")))
        }
        // A context window that would split a surrogate pair still anchors exactly.
        do {
            let reader = FakeTextFieldReader("😀" + String(repeating: "a", count: 39))
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(pollUntilDone(session) { if $0 == 1 { reader.replace("cart", with: "chart") } }.0
                    == .settled(edit("cart", "chart")))
        }
    }

    @Test func beginNeedsThePasteAtTheCaret() {
        let reader = FakeTextFieldReader("abc ")
        reader.paste("cart")
        reader.caret = 2
        #expect(begin(reader, pasted: "cart").failure == .pasteNotAtCaret, "Caret moved")
        reader.selectionLength = 2
        reader.caret = 6
        #expect(begin(reader, pasted: "cart").failure == .pasteNotAtCaret, "Non-empty selection")
        reader.selectionLength = 0
        reader.caret = 8
        #expect(begin(reader, pasted: "carts").failure == .pasteNotAtCaret, "Different text at the caret")
        #expect(begin(reader, pasted: "").failure == .pasteNotAtCaret, "Nothing pasted")
        #expect(begin(reader, pasted: "cart").isSuccess, "Paste at the caret")
        reader.supportsRangeReads = false
        #expect(begin(reader, pasted: "cart").failure == .readFailed, "No bounded reads, no session")

        let long = FakeTextFieldReader("")
        let pasted = String(repeating: "w ", count: 2100)
        long.paste(pasted)
        #expect(begin(long, pasted: pasted).failure == .tooLong, "Over the window limit")
    }

    @Test func readsAreBounded() throws {
        let big = String(repeating: "lorem ipsum ", count: 1000)
        let reader = FakeTextFieldReader(big + big)
        reader.caret = big.utf16.count
        reader.paste("cart")
        let session = try watching(reader, pasted: "cart")
        _ = pollUntilDone(session, to: 3) { if $0 == 1 { reader.replace("cart", with: "chart") } }
        #expect(reader.rangeReads.first.map { $0.length <= 4 + 80 } == true, "Begin reads the span and 40 around it")
        #expect(reader.rangeReads.dropFirst().allSatisfy { $0.length <= 40 + 4 + 200 + 40 }, "Polls read a bounded window")
        #expect(reader.rangeReads.allSatisfy { $0.length <= 4600 }, "Never more than 4,600 units")
        #expect(reader.uncheckedReads == 0, "The safety check precedes every read")
    }

    /// Losing the field finalizes the edit already read; a secure field or lost permission discards it.
    @Test func stopsAreCheckedBeforeReading() throws {
        let scenarios: [(String, (FakeTextFieldReader) -> Void, CorrectionPollOutcome)] = [
            ("focus moved", { $0.focused = false }, .finalize(edit("cart", "chart"))),
            ("secure field", { $0.secure = true }, .discard(.secureField)),
            ("read error", { $0.failReads = true }, .finalize(edit("cart", "chart"))),
            ("permission lost", { $0.trusted = false }, .discard(.notTrusted)),
        ]
        for (name, change, expected) in scenarios {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(session.poll(now: 1) == .watching)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 2) == .watching)
            let readsBefore = reader.rangeReads.count
            change(reader)
            #expect(session.poll(now: 3) == expected, "\(name)")
            #expect(reader.rangeReads.count == readsBefore, "\(name): nothing more is read")
            #expect(session.isFinished && session.record.pasted.isEmpty, "\(name): text is cleared")
            #expect(session.poll(now: 4) == expected)
        }
        // With no edit read yet, every stop discards.
        for (change, reason): ((FakeTextFieldReader) -> Void, CorrectionDiscardReason) in [
            ({ $0.focused = false }, .focusChanged), ({ $0.failReads = true }, .readFailed),
        ] {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            reader.replace("cart", with: "chart")
            change(reader)
            #expect(session.poll(now: 1) == .discard(reason))
        }
        // Capture refuses fields that cannot be watched.
        let secure = FakeTextFieldReader("")
        secure.secure = true
        #expect(secure.captureFocusedTextField() == nil, "Secure fields are never captured")
    }

    @Test func timeoutsAndCancel() throws {
        // No edit within 60 s is a timeout; an undo back to the paste is no edit.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            let (outcome, second) = pollUntilDone(session) { second in
                if second == 10 { reader.replace("cart", with: "chart") }
                if second == 11 { reader.replace("chart", with: "cart") }
            }
            #expect(outcome == .discard(.timeout) && second == 60)
        }
        // Continuous editing finalizes at 60 s with the text captured at 59 s: nothing is read at the deadline.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            let (outcome, second) = pollUntilDone(session) { reader.replace(reader.string, with: "chart\($0)") }
            #expect(outcome == .finalize(edit("cart", "chart59")) && second == 60)
        }
        // Cancel discards without finalizing.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 1) == .watching)
            session.cancel()
            #expect(session.poll(now: 9) == .discard(.cancelled))
            #expect(session.record.pasted.isEmpty, "Cancel clears text")
        }
    }

    /// A cancel that lands during an in-flight metadata request stops the watch before any text is read.
    @Test func cancelDuringRead() throws {
        do {
            let generation = CorrectionWatchGeneration()
            let token = generation.advance()
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            reader.onCharacterCount = { generation.advance() }
            let target = try #require(reader.captureFocusedTextField())
            let begun = CorrectionWatchSession.begin(reader: reader, target: target, pasted: "cart", correctionID: 7, now: 0,
                                                     isCancelled: { !generation.isCurrent(token) })
            #expect(begun.failure == .cancelled, "Begin stops on cancel")
            #expect(reader.rangeReads.isEmpty, "No text is read after the cancel")
        }
        do {
            let generation = CorrectionWatchGeneration()
            let token = generation.advance()
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let target = try #require(reader.captureFocusedTextField())
            let session = try CorrectionWatchSession.begin(reader: reader, target: target, pasted: "cart", correctionID: 7,
                                                           now: 0, isCancelled: { !generation.isCurrent(token) }).get()
            #expect(session.poll(now: 1) == .watching)
            let reads = reader.rangeReads.count
            reader.onCharacterCount = { generation.advance() }
            #expect(session.poll(now: 2) == .discard(.cancelled))
            #expect(reader.rangeReads.count == reads)
            #expect(session.record.pasted.isEmpty, "Text is cleared")
        }
    }

    /// Past the 60 s window nothing is read again. A late poll finalizes from text captured inside the window, or
    /// discards.
    @Test func deadlineStopsReads() throws {
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            #expect(session.poll(now: 1) == .watching)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 2) == .watching)
            reader.replace("chart", with: "chart typed after the window")
            let reads = reader.rangeReads.count
            #expect(session.poll(now: 75) == .finalize(edit("cart", "chart")))
            #expect(reader.rangeReads.count == reads)
        }
        do {
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let session = try watching(reader, pasted: "cart")
            reader.replace("cart", with: "chart")
            let reads = reader.rangeReads.count
            #expect(session.poll(now: 75) == .discard(.timeout))
            #expect(reader.rangeReads.count == reads)
        }
        // A metadata request that crosses the deadline: no text read follows.
        for edited in [false, true] {
            let clock = TestClock()
            let reader = FakeTextFieldReader("Note: ")
            reader.paste("cart")
            let target = try #require(reader.captureFocusedTextField())
            let session = try CorrectionWatchSession.begin(reader: reader, target: target, pasted: "cart", correctionID: 7,
                                                           now: 0, clock: { clock.now }).get()
            if edited { reader.replace("cart", with: "chart") }
            clock.now = 2
            #expect(session.poll(now: 2) == .watching)
            reader.replace(reader.string.hasSuffix("chart") ? "chart" : "cart", with: "late")
            let reads = reader.rangeReads.count
            reader.onCharacterCount = { clock.now = 60.5 }
            clock.now = 59.9
            let outcome = session.poll(now: 59.9)
            #expect(reader.rangeReads.count == reads)
            #expect(outcome == (edited ? .finalize(edit("cart", "chart")) : .discard(.timeout)))
            #expect(session.record.pasted.isEmpty, "Text is cleared")
        }
    }

    /// At the deadline, cached text is finalized only if the field is not secure and permission remains; the checks
    /// are metadata, never text. Moving focus does not prevent it: the edit was read while the field was focused.
    @Test func expiryRechecksSafety() throws {
        let changes: [(String, (FakeTextFieldReader) -> Void, CorrectionPollOutcome)] = [
            ("focus moved", { $0.focused = false }, .finalize(edit("cart", "chart59"))),
            ("secure field", { $0.secure = true }, .discard(.secureField)),
            ("permission lost", { $0.trusted = false }, .discard(.notTrusted)),
            ("unchanged", { _ in }, .finalize(edit("cart", "chart59"))),
        ]
        for (name, change, expected) in changes {
            for late in [false, true] {
                let reader = FakeTextFieldReader("")
                reader.paste("cart")
                let session = try watching(reader, pasted: "cart")
                // Editing through 59 s, so the quiet period never finalizes early.
                for second in 1...59 {
                    reader.replace(reader.string, with: "chart\(second)")
                    #expect(session.poll(now: TimeInterval(second)) == .watching)
                }
                change(reader)
                let reads = reader.rangeReads.count
                #expect(session.poll(now: late ? 75 : 60) == expected, "\(name) at expiry")
                #expect(reader.rangeReads.count == reads)
            }
        }
    }

    /// An edit is reported 1.5 s after it was last seen to change, and the watch continues: each later distinct edit
    /// is reported again, up to three reports, the last of which ends the watch.
    @Test func keepsWatchingAfterACheck() throws {
        #expect(CorrectionWatchSession.quietPeriod == 1.5 && CorrectionWatchSession.maxChecks == 3)
        #expect(CorrectionWatcher.pollInterval == 0.5)
        let typed = "ship the cart to fred now"
        let reader = FakeTextFieldReader("Note: ")
        reader.paste(typed)
        let session = try watching(reader, pasted: typed)
        #expect(session.poll(now: 0.5) == .watching)
        reader.replace("cart", with: "chart")
        #expect(session.poll(now: 1.0) == .watching)
        #expect(session.poll(now: 1.5) == .watching)
        #expect(session.poll(now: 2.0) == .watching)
        #expect(session.poll(now: 2.5) == .settled(edit(typed, "ship the chart to fred now")))
        // The same edit is not reported twice, and the watch goes on reading.
        let reads = reader.rangeReads.count
        #expect(session.poll(now: 3.0) == .watching)
        #expect(session.poll(now: 9.0) == .watching)
        #expect(reader.rangeReads.count > reads && !session.isFinished, "Still watching after a report")
        // A later edit is reported in full, against the original paste.
        reader.replace("fred", with: "Fred")
        #expect(session.poll(now: 10.0) == .watching)
        #expect(session.poll(now: 11.5) == .settled(edit(typed, "ship the chart to Fred now")))
        // Returning to the reported state is not a new edit.
        reader.replace("Fred", with: "Ted")
        #expect(session.poll(now: 12.0) == .watching)
        reader.replace("Ted", with: "Fred")
        #expect(session.poll(now: 12.5) == .watching)
        #expect(session.poll(now: 20.0) == .watching)
        // The third report is the last.
        reader.replace("now", with: "today")
        #expect(session.poll(now: 21.0) == .watching)
        #expect(session.poll(now: 22.5) == .finalize(edit(typed, "ship the chart to Fred today")))
        #expect(session.isFinished && session.record.pasted.isEmpty, "Text is cleared after the last report")
        let finalReads = reader.rangeReads.count
        _ = session.poll(now: 23.0)
        #expect(reader.rangeReads.count == finalReads)

        // An undo back to the paste is never reported.
        let undo = FakeTextFieldReader("")
        undo.paste("cart")
        let undone = try watching(undo, pasted: "cart")
        undo.replace("cart", with: "chart")
        #expect(undone.poll(now: 0.5) == .watching)
        undo.replace("chart", with: "cart")
        #expect(undone.poll(now: 1.0) == .watching)
        #expect(undone.poll(now: 5.0) == .watching)
    }

    /// When the field can no longer be followed, the last edit read is finalized from memory if it was not checked
    /// yet. Nothing more is read.
    @Test func watchEndsWithCapturedEdit() throws {
        let typed = "ship the cart now. "
        // A chat field that clears on send: before the quiet period, and after a report.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            reader.replace("ship the chart now. ", with: "")
            let reads = reader.rangeReads.count
            #expect(session.poll(now: 1.0) == .finalize(edit(typed, "ship the chart now. ")))
            #expect(reader.rangeReads.count == reads + 1, "Only the read that found it cleared")
            #expect(session.record.pasted.isEmpty, "Text is cleared")
        }
        do {
            let reader = FakeTextFieldReader("")
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            #expect(session.poll(now: 2.0) == .settled(edit(typed, "ship the chart now. ")))
            reader.replace("ship the chart now. ", with: "")
            #expect(session.poll(now: 2.5) == .discard(.spanRemoved), "Already checked")
        }
        // A field with text before the span that clears entirely.
        do {
            let reader = FakeTextFieldReader("Intro line.\n")
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            reader.replace("Intro line.\nship the chart now. ", with: "")
            #expect(session.poll(now: 1.0) == .finalize(edit(typed, "ship the chart now. ")))
        }
        // Focus moves after an unchecked edit: finalized without another read.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            reader.focused = false
            let reads = reader.rangeReads.count
            #expect(session.poll(now: 1.0) == .finalize(edit(typed, "ship the chart now. ")))
            #expect(reader.rangeReads.count == reads)
        }
        // Focus moves after the edit was checked: nothing new to check.
        do {
            let reader = FakeTextFieldReader("")
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            #expect(session.poll(now: 2.0) == .settled(edit(typed, "ship the chart now. ")))
            reader.focused = false
            #expect(session.poll(now: 2.5) == .discard(.focusChanged))
        }
        // Anchor changes and a cancel: finalized, and discarded respectively.
        do {
            let reader = FakeTextFieldReader("Intro line.\n" + longAfter)
            reader.caret = 12
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            reader.replace("Intro", with: "Outro")
            #expect(session.poll(now: 1.0) == .finalize(edit(typed, "ship the chart now. ")))
        }
        do {
            let reader = FakeTextFieldReader("")
            reader.paste(typed)
            let session = try watching(reader, pasted: typed)
            reader.replace("cart", with: "chart")
            #expect(session.poll(now: 0.5) == .watching)
            session.cancel()
            #expect(session.poll(now: 1.0) == .discard(.cancelled))
        }
    }

    /// Browsers show a trailing or repeated space as a no-break space and switch it back as the text changes. Read
    /// from the field it counts as a space: the paste still matches, a switch alone is no edit, and a real edit reads
    /// with ordinary spaces.
    @Test func noBreakSpacesCountAsSpaces() throws {
        let nbsp = "\u{00A0}"
        do {
            let reader = FakeTextFieldReader("Note:" + nbsp)
            reader.paste("cart" + nbsp)
            let session = try begin(reader, pasted: "cart ").get()
            let (switched, _) = pollUntilDone(session, to: 5) {
                if $0 == 1 {
                    reader.replace("Note:" + nbsp, with: "Note: ")
                    reader.replace("cart" + nbsp, with: "cart ")
                }
            }
            #expect(switched == .watching, "Switching spaces is no edit")
            let (edited, _) = pollUntilDone(session, from: 6, to: 12) {
                if $0 == 6 { reader.replace("cart ", with: "chart" + nbsp) }
            }
            #expect(edited == .settled(edit("cart ", "chart ")))
        }
        do {
            let reader = FakeTextFieldReader("Intro" + nbsp + nbsp + "line.\n")
            reader.paste("ten  kg ")
            #expect(begin(reader, pasted: "ten" + nbsp + " kg ").isSuccess, "A pasted no-break space matches a space")
            reader.replace("ten  kg ", with: "ten  kh ")
            #expect(begin(reader, pasted: "ten  kg ").failure == .pasteNotAtCaret, "Other differences still fail")
        }
    }

    @Test func generations() {
        let generation = CorrectionWatchGeneration()
        let first = generation.advance()
        #expect(generation.isCurrent(first), "Current")
        #expect(generation.advance(from: first) == first + 1)
        #expect(generation.advance(from: first) == nil, "A stale generation cannot advance")
        #expect(!generation.isCurrent(first), "Stale after cancel")
        // Contended claims of one generation: exactly one wins, and the losers change nothing.
        for _ in 0..<500 {
            let current = generation.current
            let wins = Counter()
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                if generation.advance(from: current) != nil { wins.increment() }
            }
            #expect(wins.value == 1 && generation.current == current + 1)
        }
    }
}

/// A clock a test moves by hand, readable from the session's closures.
final class TestClock: Sendable {
    private let value = Mutex<TimeInterval>(0)
    var now: TimeInterval {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

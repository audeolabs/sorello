import Foundation
import Testing
@testable import DictionaryKit

/// Correction candidates, verification, budgets, the strength probe, and presenting a suggestion (DESIGN §1.5,
/// §1.6, §3.4, §3.5; pins P1, P2, P3, P5, P8).
struct CorrectionTests {
    func candidates(_ before: String, _ after: String, dictionary: [String] = [],
                    ignore: [String] = []) -> [CorrectionCandidate] {
        CorrectionCandidates.find(before: before, after: after, dictionary: dictionary.map { entry($0) },
                                  ignore: Set(ignore.map(DictionaryKey.init)), encoder: testEncoder)
    }

    @Test func candidateHandCases() {
        let kubernetes = candidates("we deployed it on cooper netties yesterday", "we deployed it on Kubernetes yesterday")
        #expect(kubernetes.count == 1)
        expectScalars(kubernetes[0].surface, "Kubernetes")
        #expect(kubernetes[0].kind == .replace)
        #expect(kubernetes[0].beforeRange == 4..<6)
        #expect(kubernetes[0].beforeWords == [s("cooper"), s("netties")], "Before words are norms")

        #expect(candidates("please send the report today", "can you email me the summary").isEmpty, "Rewrite")
        let nixos = candidates("nixos", "NixOS")
        #expect(nixos.count == 1 && nixos.first?.kind == .casing, "Casing candidate")
        expectScalars(nixos.first?.surface ?? "", "NixOS")
        let sharp = candidates("i write sea sharp code", "i write C# code")
        #expect(sharp.count == 1 && sharp.first?.kind == .replace, "C# keeps its symbol")
        expectScalars(sharp.first?.surface ?? "", "C#")
        #expect(candidates("ping the cooper netties team", "ping the Kubernetes team", dictionary: ["kubernetes"]).isEmpty,
                "Known words are not suggested")
        #expect(candidates("ping the cooper netties team", "ping the Kubernetes team", ignore: ["kubernetes"]).isEmpty,
                "Ignored words are not suggested")
        #expect(candidates("hello world", "hello big world").isEmpty, "Pure insertions do not qualify")
        let naive = candidates("the naive approach", "the Naïve approach")
        #expect(naive.count == 1 && naive.first?.kind == .replace, "naive ≠ naïve")
        expectScalars(naive.first?.surface ?? "", "Naïve")
        // P1: a capitalised first letter alone is not a casing candidate.
        #expect(candidates("the plan works", "The plan works").isEmpty, "Sentence-start capitalisation")
        #expect(candidates("we use kubernetes", "we use Kubernetes").isEmpty, "Initial capital only")
        let newYork = candidates("i love new york", "i love New York")
        #expect(newYork.count == 1 && newYork.first?.kind == .casing, "Two-word casing block")
        expectScalars(newYork.first?.surface ?? "", "New York")
        #expect(newYork.first?.beforeRange == 2..<4)
        // Outer edge punctuation is stripped from the surface only.
        let quoted = candidates("try cooper netties.", "try “Kubernetes.”")
        #expect(quoted.count == 1, "Quoted replacement")
        expectScalars(quoted.first?.surface ?? "", "Kubernetes")
        // Short corrections are not rewrites; four words of five are.
        #expect(candidates("cart", "chart").count == 1)
        #expect(candidates("a b c d e", "a v w x y").isEmpty, "Over half the words changed")
        // Blocks of more than three words do not qualify.
        #expect(candidates("one two three four five six seven eight nine ten",
                           "one zwei drei vier funf six seven eight nine ten").isEmpty, "Four-word block")
        // Bounds are checked before any alignment.
        let long = Array(repeating: "word", count: 201).joined(separator: " ")
        #expect(candidates(long, long + "s").isEmpty, "More than 200 words")
        #expect(candidates(String(repeating: "é", count: 2049), "x").isEmpty, "More than 4096 UTF-8 bytes")
        // Unencodable surfaces never become candidates.
        #expect(candidates("the cart now", "the ¢art now").isEmpty, "Unencodable surface")
        // Multiple qualifying blocks in text order.
        let two = candidates("use the alder package and review the cart patch",
                             "use the Eldar package and review the chart patch")
        #expect(two.map { s($0.surface) } == [s("Eldar"), s("chart")], "Blocks are returned in text order")

        // P2 alignment order: diagonal, then deletion, then insertion.
        #expect(WordAlignment.align([s("a"), s("b")], [s("c")]) == [.delete(a: 0, beforeB: 0), .substitute(a: 1, b: 0)])
        #expect(WordAlignment.align([s("c")], [s("a"), s("b")]) == [.insert(b: 0, beforeA: 0), .substitute(a: 0, b: 1)])
    }

    func verifyStrength(base: String, before: String, after: String, candidateIndex: Int = 0,
                        decoded: [Float: String]) -> Float? {
        let found = candidates(before, after)
        guard found.indices.contains(candidateIndex) else { return nil }
        let candidate = found[candidateIndex]
        for strength in VerifyDecision.strengths {
            let n = decoded[strength] ?? base
            if VerifyDecision.accepts(typed: before, candidate: candidate, base: base, decoded: n) { return strength }
        }
        return nil
    }

    @Test func verifyHandCases() {
        let v1before = "we deployed it on cooper netties yesterday"
        let v1after = "we deployed it on Kubernetes yesterday"
        #expect(verifyStrength(base: v1before, before: v1before, after: v1after,
                               decoded: [1.41: "we deployed it on kubernetes yesterday"]) == 1.41)
        let v2 = "use the alder package and review the alder patch"
        #expect(verifyStrength(base: v2, before: v2, after: "use the Eldar package and review the alder patch",
                               decoded: [1.0: "use the alder package and review the eldar patch",
                                         1.41: "use the eldar package and review the eldar patch"]) == 1.41)
        #expect(verifyStrength(base: "ship the cart now", before: "ship the cart now", after: "ship the chart now",
                               decoded: [1.0: "ship the cart chart now", 1.41: "ship the chart now"]) == 1.41)
        let monday = "we deploy to kubernetes on monday after lunch"
        #expect(verifyStrength(base: "we deploy to cooper netties on friday after lunch", before: v1before, after: v1after,
                               decoded: Dictionary(uniqueKeysWithValues: VerifyDecision.strengths.map { ($0, monday) }))
                == nil)
        // The typed text may carry text rules (a tag, punctuation); the block maps through alignment.
        #expect(verifyStrength(base: "ship the cart now", before: "[dictated] Ship the cart now.",
                               after: "[dictated] Ship the chart now.", decoded: [2.0: "Ship the chart now"]) == 2.0)
        // The block's words must match B exactly; otherwise reject.
        #expect(verifyStrength(base: "ship the kart now", before: "ship the cart now", after: "ship the chart now",
                               decoded: [1.0: "ship the chart now"]) == nil)
        // P3: an extra N word just past the window's end counts as a window edit.
        #expect(verifyStrength(base: "a b cart c d e f", before: "a b cart c d e f", after: "a b chart c d e f",
                               decoded: [1.0: "a b chart c d zz e f", 1.41: "a b chart c d e f"]) == 1.41)
    }

    private func find(typed: String, edited: String, base: String, dictionary: [DictionaryEntry] = [],
                      exhausted: ExhaustedCandidates = ExhaustedCandidates(), clock: () -> TimeInterval = { 0 },
                      cancelled: () -> Bool = { false },
                      decode: (DictionaryEntry) -> String?) -> DictionarySuggestion? {
        DictionarySuggestionFinder.find(typed: typed, edited: edited, base: base, dictionary: dictionary, ignore: [],
                                        encoder: testEncoder, exhausted: exhausted, now: clock, isCancelled: cancelled,
                                        decode: decode)
    }

    @Test func suggestionBudgets() {
        let typed = "one two three four five six seven eight nine ten"
        let edited = "one zwei three vier five sechs seven acht nine ten"
        var calls: [DictionaryEntry] = []
        #expect(find(typed: typed, edited: edited, base: typed) { calls.append($0); return typed } == nil, "Nothing verifies")
        #expect(calls.count == 21, "Three candidates, seven strengths each")
        #expect(VerifyDecision.strengths == [1, 1.41, 2, 2.83, 4, 5.66, 8])
        #expect(calls.prefix(7).map(\.strength) == VerifyDecision.strengths)
        expectScalars(calls[7].text, "vier")

        var time: TimeInterval = 0
        calls = []
        #expect(find(typed: typed, edited: edited, base: typed, clock: { time }) {
            calls.append($0); time += 0.5; return typed
        } == nil, "Budget")
        #expect(calls.count == 6, "The 3 s budget is spent by the end of the sixth decode")

        calls = []
        #expect(find(typed: typed, edited: edited, base: typed, cancelled: { calls.count >= 2 }) {
            calls.append($0); return typed
        } == nil, "Cancel")
        #expect(calls.count == 2)

        calls = []
        let accepted = find(typed: typed, edited: edited, base: typed) { candidate in
            calls.append(candidate)
            return candidate.strength >= 2 ? "one zwei three four five six seven eight nine ten" : typed
        }
        #expect(accepted == DictionarySuggestion(word: "zwei", strength: 2, kind: .replace), "First accepted strength wins")
        #expect(calls.count == 3)

        calls = []
        let casing = find(typed: "we run nixos", edited: "we run NixOS", base: "we run nixos") { calls.append($0); return nil }
        #expect(casing == DictionarySuggestion(word: "NixOS", strength: 1, kind: .casing), "Casing needs no audio")
        #expect(calls.isEmpty, "Casing candidates are never decoded")
        #expect(find(typed: typed, edited: edited, base: typed) { _ in nil } == nil, "A decode failure ends the check")
    }

    /// Pin P8: candidates that cannot be attempted do not spend the budget.
    @Test func verificationOrder() {
        var time: TimeInterval = 0
        var calls: [DictionaryEntry] = []
        let found = find(typed: "[dictated] ship the cart now", edited: "[spoken] ship the chart now",
                         base: "ship the cart now", clock: { time }) { entry in
            calls.append(entry)
            time += 0.5
            return entry.strength >= 1.41 ? "ship the chart now" : "ship the cart now"
        }
        #expect(found == DictionarySuggestion(word: "chart", strength: 1.41, kind: .replace), "The mappable one verifies")
        #expect(calls.allSatisfy { s($0.text) == s("chart") }, "The unmappable candidate is never decoded")
        #expect(calls.count == 2)

        // Unmappable candidates are dropped before the three-candidate cap.
        let base = "one two three four five six seven eight nine ten"
        calls = []
        _ = find(typed: "[dictated] " + base, edited: "[spoken] one zwei three vier five sechs seven acht nine ten",
                 base: base) { calls.append($0); return base }
        #expect(calls.count == 21)
        #expect(Set(calls.map(\.text)) == ["zwei", "vier", "sechs"], "Three mappable candidates are attempted")

        // One unmappable candidate, then three mappable ones where the third recovers: 7 + 7 + 1 decodes.
        calls = []
        let third = find(typed: "[dictated] " + base, edited: "[spoken] one zwei three vier five sechs seven eight nine ten",
                         base: base) { entry in
            calls.append(entry)
            return s(entry.text) == s("sechs") ? "one two three four five sechs seven eight nine ten" : base
        }
        #expect(third == DictionarySuggestion(word: "sechs", strength: 1, kind: .replace))
        #expect(calls.count == 15)

        // A result that arrives past the deadline is discarded, even if it verifies.
        time = 0
        calls = []
        let late = find(typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
                        clock: { time }) { calls.append($0); time += 3.5; return "ship the chart now" }
        #expect(late == nil && calls.count == 1, "Late results are discarded")

        // Cancellation during a decode also discards its result.
        var cancelled = false
        let interrupted = find(typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
                               cancelled: { cancelled }) { _ in cancelled = true; return "ship the chart now" }
        #expect(interrupted == nil, "Cancelled results are discarded")

        // Casing candidates respect the deadline and cancellation too.
        var clock: [TimeInterval] = [0, 3]
        #expect(find(typed: "we run nixos", edited: "we run NixOS", base: "we run nixos",
                     clock: { clock.count > 1 ? clock.removeFirst() : clock[0] }) { _ in nil } == nil, "Casing past the deadline")
        #expect(find(typed: "we run nixos", edited: "we run NixOS", base: "we run nixos", cancelled: { true }) { _ in nil }
                == nil, "Casing when cancelled")
    }

    /// A candidate decoded at every strength without being accepted is not decoded again by a later check of the
    /// same dictation; one cut short by the budget is.
    @Test func exhaustedCandidatesAreSkipped() {
        let typed = "ship the cart to fred now"
        let exhausted = ExhaustedCandidates()
        var calls: [DictionaryEntry] = []
        #expect(find(typed: typed, edited: "ship the chart to fred now", base: typed, exhausted: exhausted) {
            calls.append($0); return typed
        } == nil, "Not recovered")
        #expect(calls.count == 7)
        calls = []
        let found = find(typed: typed, edited: "ship the chart to fried now", base: typed, exhausted: exhausted) { entry in
            calls.append(entry)
            return s(entry.text) == s("fried") && entry.strength >= 2 ? "ship the cart to fried now" : typed
        }
        #expect(found == DictionarySuggestion(word: "fried", strength: 2, kind: .replace), "The new candidate verifies")
        #expect(calls.allSatisfy { s($0.text) == s("fried") }, "The exhausted candidate is skipped")
        #expect(calls.count == 3)

        let fresh = ExhaustedCandidates()
        var time: TimeInterval = 0
        calls = []
        _ = find(typed: typed, edited: "ship the chart to fred now", base: typed, exhausted: fresh, clock: { time }) {
            calls.append($0); time += 1; return typed
        }
        #expect(calls.count == 3)
        calls = []
        _ = find(typed: typed, edited: "ship the chart to fred now", base: typed, exhausted: fresh) {
            calls.append($0); return typed
        }
        #expect(calls.count == 7, "A candidate cut short by the budget is tried again")
    }

    /// A full dictionary could not take the word, so nothing is offered or decoded.
    @Test func fullDictionaryOffersNothing() {
        let full = (0..<DictionaryValidation.capacity).map { entry("word\($0)x") }
        var calls = 0
        #expect(find(typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now", dictionary: full) {
            _ in calls += 1; return "ship the chart now"
        } == nil && calls == 0, "No replacement offered at capacity")
        #expect(find(typed: "we run nixos", edited: "we run NixOS", base: "we run nixos", dictionary: full) { _ in nil }
                == nil, "No casing suggestion at capacity")
        #expect(find(typed: "ship the cart now", edited: "ship the chart now", base: "ship the cart now",
                     dictionary: Array(full.dropLast())) { _ in "ship the chart now" } != nil,
                "One free slot still offers the word")
    }

    @Test func strengthProbeContains() {
        #expect(StrengthProbe.contains("Zorblax", in: "we shipped zorblax, finally."), "folded, edge punctuation")
        #expect(StrengthProbe.contains("Quint Morrow", in: "ask quint morrow today"), "a phrase")
        #expect(!StrengthProbe.contains("Quint Morrow", in: "ask quint and morrow"), "words apart")
        #expect(!StrengthProbe.contains("Zorblax", in: "zorb lax"), "split word")
        #expect(!StrengthProbe.contains("Zorblax", in: ""), "empty text")
    }

    @Test func strengthProbeAcceptance() {
        let base = "we moved the service to zor blacks last week"
        #expect(StrengthProbe.accepts(word: "Zorblax", base: base, decoded: "we moved the service to Zorblax last week"))
        #expect(!StrengthProbe.accepts(word: "Zorblax", base: base, decoded: "we moved the service to Zorblax last month"),
                "another change elsewhere")
        #expect(!StrengthProbe.accepts(word: "Zorblax", base: base, decoded: base), "no change")
        #expect(!StrengthProbe.accepts(word: "Zorblax", base: base, decoded: "we moved the service to Zorblax lax week"),
                "the word plus a neighbouring change")
        #expect(StrengthProbe.accepts(word: "Zorblax", base: "use zor bla ax now", decoded: "use Zorblax now"),
                "three words for one")
        #expect(!StrengthProbe.accepts(word: "Zorblax", base: "use it with zor blacks now", decoded: "use Zorblax now"),
                "a block swallowing four words")
        #expect(StrengthProbe.accepts(word: "Zorblax", base: "zor blacks and zor blacks", decoded: "Zorblax and Zorblax"),
                "every occurrence replaced")
        #expect(StrengthProbe.accepts(word: "Zorblax", base: "we use it", decoded: "we use Zorblax it"), "an inserted word")
    }

    @Test func strengthProbeFind() {
        var tried: [Float] = []
        let result = StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { strength in
            tried.append(strength)
            return strength >= 2.83 ? "ship Zorblax today" : "ship zor blacks today"
        }
        #expect(tried == [1, 1.41, 2, 2.83])
        #expect(result == StrengthProbe.Result(outcome: .recognized(strength: 2.83), base: "ship zor blacks today",
                                               boosted: "ship Zorblax today"))

        var calls = 0
        let already = StrengthProbe.find(word: "Zorblax", base: "ship Zorblax today") { _ in calls += 1; return "" }
        #expect(already.outcome == .alreadyRecognized && already.boosted == nil && calls == 0)

        tried = []
        let missed = StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { strength in
            tried.append(strength)
            return "ship Zorblax tomorrow"
        }
        #expect(missed == StrengthProbe.Result(outcome: .notRecognized, base: "ship zor blacks today", boosted: nil))
        #expect(tried == VerifyDecision.strengths)

        struct Stop: Error {}
        calls = 0
        #expect(throws: Stop.self) {
            try StrengthProbe.find(word: "Zorblax", base: "ship zor blacks today") { _ throws(Stop) -> String in
                calls += 1
                throw Stop()
            }
        }
        #expect(calls == 1, "A failed decode ends the probe")
    }

    @Test func suggestionGate() {
        let eldar = DictionarySuggestion(word: "Eldar", strength: 1.41, kind: .replace)
        let chart = DictionarySuggestion(word: "chart", strength: 2, kind: .replace)
        var gate = SuggestionPresentationGate()
        let first = gate.present(eldar)
        #expect(gate.activeID == first && gate.suggestion == eldar, "Presented")
        gate.preempt()
        #expect({ gate.resolve(first) }() == nil, "A pre-empted suggestion's timer does nothing")
        let second = gate.present(chart)
        #expect({ gate.resolve(first) }() == nil, "A stale timer cannot dismiss a later suggestion")
        #expect(gate.activeID == second && gate.suggestion == chart, "Still showing the later suggestion")
        #expect({ gate.resolve(second) }() == chart, "Its own action resolves it, with its word")
        #expect({ gate.resolve(second) }() == nil, "Only once")
        #expect(gate.suggestion == nil && gate.activeID == nil, "Resolving clears the word")
        #expect(SuggestionPresentationGate.lifetime == 12)
    }

    @Test func suggestionWithdrawal() throws {
        let word = DictionarySuggestion(word: "Kubernetes", strength: 1, kind: .replace)
        var gate = SuggestionPresentationGate()
        let presented = gate.present(word, requestedAt: gate.withdrawals)
        let visible = try #require(presented)
        #expect(gate.suggestion == word, "Shown")
        gate.withdraw()
        #expect(gate.suggestion == nil && gate.activeID == nil, "Withdrawn and cleared")
        #expect({ gate.resolve(visible) }() == nil, "Its buttons and timer do nothing")
        let requested = gate.withdrawals
        gate.withdraw()
        #expect({ gate.present(word, requestedAt: requested) }() == nil && gate.suggestion == nil,
                "A presentation requested before the withdrawal never shows")
        let later = gate.withdrawals
        #expect({ gate.present(word, requestedAt: later) }() != nil && gate.suggestion == word, "A later one shows")
    }

    @Test func presentationTiming() {
        #expect(CorrectionSuggestionTiming.mayPresent(enabled: true, dictionaryEditable: true, recording: false,
                                                      transcribing: false, startPending: false,
                                                      shortcutSessionActive: false))
        let blocked = [(false, true, false, false, false, false), (true, false, false, false, false, false),
                       (true, true, true, false, false, false), (true, true, false, true, false, false),
                       (true, true, false, false, true, false), (true, true, false, false, false, true)]
        for (enabled, editable, recording, transcribing, pending, active) in blocked {
            #expect(!CorrectionSuggestionTiming.mayPresent(enabled: enabled, dictionaryEditable: editable,
                                                           recording: recording, transcribing: transcribing,
                                                           startPending: pending, shortcutSessionActive: active))
        }
    }

    /// An edit between recording and insertion, or any later cancel, leaves the result ineligible.
    @Test func eligibilityWindow() {
        func eligible(snapshot: UInt64 = 3, current: UInt64 = 3, watch: UInt64 = 5, now: UInt64 = 5,
                      enabled: Bool = true, retained: Bool = true, macro: Bool = false, enter: Bool = false,
                      output: String = "ship the cart now") -> Bool {
            CorrectionEligibility.isEligible(suggestionsEnabled: enabled, retained: retained,
                                             snapshotRevision: snapshot, currentRevision: current,
                                             watchGeneration: watch, currentGeneration: now,
                                             usedMacro: macro, pressesEnter: enter, output: output)
        }
        #expect(eligible(), "A plain current dictation is eligible")
        #expect(!eligible(current: 4), "A dictionary edit after recording started")
        #expect(!eligible(now: 6), "A cancel after the text was composed")
        #expect(!eligible(enabled: false) && !eligible(retained: false), "Setting off, or nothing retained")
        #expect(!eligible(macro: true) && !eligible(enter: true) && !eligible(output: ""), "Macro, enter, empty")
        #expect(eligible(output: String(repeating: "a", count: 4096)) && !eligible(output: String(repeating: "a", count: 4097)),
                "At most 4096 bytes")
    }
}

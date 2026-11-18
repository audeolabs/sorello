import DictionaryKit
import Foundation

/// The top row's offer to add a word the user fixed in a dictation to the dictionary (ARCHITECTURE.md, "Dictation
/// corrections"): its word and the dictation's words it replaces. In memory only.
struct DictationCorrectionOffer: Equatable, Sendable {
    /// The dictation's request.
    var requestID: UUID
    /// As the offer shows it: the candidate's surface (DictionaryKit `CorrectionOffer.word`).
    var word: String
    /// Whitespace-split indices of the dictation's words it replaces, half open.
    var replacedWords: Range<Int>
}

/// Dictation corrections (ARCHITECTURE.md, "Dictation corrections"): watches the dictation the keyboard just inserted
/// and, once the text has been quiet, looks for a fix to one of its words. Pure; `EditingCore` owns it.
///
/// - **The watch** holds, in memory only, the request id, the text as inserted (trimmed), up to `anchorLength`
///   characters of the context before it and after it (as Undo reads them), the field and the time. Nothing else.
/// - **Where the dictation is now** is read from the proxy, never kept, and only where each anchor places its end
///   without doubt (`locate`): a context the keyboard cannot place means a missed offer, never a wrong one.
/// - **When.** Every activity (`activity`) restarts the wait and ends the offer; the edit is checked once
///   `quietPeriod` has passed since the last, and not again until the next activity.
/// - **The watch ends** at `lifetime` after the insertion, and when its owner ends it.
struct DictationCorrectionWatch: Equatable, Sendable {
    static let quietPeriod: TimeInterval = 0.75
    static let lifetime: TimeInterval = 60
    static let anchorLength = UndoTracker.anchorLength
    /// The most words the dictation as edited may have, with what was typed around it, to be checked at all: the
    /// alignment's memory grows with them, and the keyboard has little. Five times DictionaryKit's own bound.
    static let maxEditedWords = 1000

    struct Watched: Equatable, Sendable {
        var requestID: UUID
        /// The dictation as inserted, trimmed.
        var text: String
        var anchorBefore: String
        var anchorAfter: String
        var documentID: UUID
        var insertedAt: TimeInterval
    }

    private(set) var watched: Watched?
    /// The last activity not yet followed by a check; nil when there is nothing to check.
    private(set) var activityAt: TimeInterval?
    private(set) var offer: DictationCorrectionOffer?

    var isWatching: Bool { watched != nil }

    /// When the next check is due, nil when none is.
    var checkDue: TimeInterval? { watched == nil ? nil : activityAt.map { $0 + Self.quietPeriod } }

    /// Whether `text` (trimmed) can be watched: not empty, and within DictionaryKit's bounds (DESIGN §1.5.1).
    static func isWatchable(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4096
            && text.split(whereSeparator: { $0.isWhitespace }).count <= 200
    }

    /// A dictation was inserted: `inserted` is the text that went in, `contextBefore` and `contextAfter` the context
    /// read just before inserting it. Replaces any earlier watch; watches nothing without a field or with a text that
    /// cannot be watched.
    mutating func start(requestID: UUID, inserted: String, contextBefore: String?, contextAfter: String?,
                        documentID: UUID?, at time: TimeInterval) {
        end()
        let text = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let documentID, Self.isWatchable(text) else { return }
        watched = Watched(requestID: requestID, text: text,
                          anchorBefore: String((contextBefore ?? "").suffix(Self.anchorLength)),
                          anchorAfter: String((contextAfter ?? "").prefix(Self.anchorLength)),
                          documentID: documentID, insertedAt: time)
    }

    /// Ends the watch: its text, anchors and offer go.
    mutating func end() {
        watched = nil
        activityAt = nil
        offer = nil
    }

    /// A key, strip choice, swipe, trackpad movement or text or selection callback: the wait starts over and the offer
    /// ends.
    mutating func activity(at now: TimeInterval) {
        guard watched != nil else { return }
        activityAt = now
        offer = nil
    }

    /// Ends the watch once `lifetime` has passed since the insertion (or the clock went back).
    mutating func expire(now: TimeInterval) {
        guard let watched else { return }
        let age = now - watched.insertedAt
        if age < 0 || age >= Self.lifetime { end() }
    }

    /// Checks the edit if the text has been quiet for `quietPeriod`: the proxy's context of the watch's field, with
    /// nothing selected, locates the dictation as edited, and DictionaryKit's `CorrectionOffer` finds the offer.
    mutating func check(documentID: UUID?, before: String?, after: String?, hasSelection: Bool, now: TimeInterval) {
        expire(now: now)
        guard let watched, let due = checkDue, now >= due else { return }
        activityAt = nil
        guard documentID == watched.documentID, !hasSelection,
              let edited = Self.locate(anchorBefore: watched.anchorBefore, anchorAfter: watched.anchorAfter,
                                       before: before ?? "", after: after ?? "")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              edited != watched.text,
              CorrectionOffer.wordCount(edited) <= Self.maxEditedWords,
              let found = CorrectionOffer.find(typed: watched.text, edited: edited) else { return }
        offer = DictationCorrectionOffer(requestID: watched.requestID, word: found.word,
                                         replacedWords: found.replacedWords)
    }

    /// The dictation as edited: what lies between the before-anchor, in the text before the caret, and the
    /// after-anchor, in the text after it. A full anchor must occur exactly once on its side; a shorter one (the field's
    /// start or end was that close) must sit at the very start of the text before the caret, or the very end of the
    /// text after it, and occur nowhere else there. Nil when an anchor does not place its end.
    static func locate(anchorBefore: String, anchorAfter: String, before: String, after: String) -> String? {
        let start: String.Index
        if anchorBefore.count >= anchorLength {
            guard let only = onlyOccurrence(of: anchorBefore, in: before) else { return nil }
            start = only.upperBound
        } else {
            guard before.hasPrefix(anchorBefore), anchorBefore.isEmpty || occurrences(of: anchorBefore, in: before) == 1
            else { return nil }
            start = before.index(before.startIndex, offsetBy: anchorBefore.count)
        }
        let end: String.Index
        if anchorAfter.count >= anchorLength {
            guard let only = onlyOccurrence(of: anchorAfter, in: after) else { return nil }
            end = only.lowerBound
        } else {
            guard after.hasSuffix(anchorAfter), anchorAfter.isEmpty || occurrences(of: anchorAfter, in: after) == 1
            else { return nil }
            end = after.index(after.endIndex, offsetBy: -anchorAfter.count)
        }
        return String(before[start...]) + String(after[..<end])
    }

    private static func onlyOccurrence(of needle: String, in text: String) -> Range<String.Index>? {
        guard occurrences(of: needle, in: text) == 1 else { return nil }
        return text.range(of: needle, options: .literal)
    }

    /// Every occurrence, overlapping ones included, character by character.
    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
            count += 1
            from = text.index(after: found.lowerBound)
        }
        return count
    }
}

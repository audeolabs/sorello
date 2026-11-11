import Foundation

// One watched paste (DESIGN §3.5). Accessibility is reached only through `TextFieldReading`; MacPlatform supplies
// the real reader and tests a fake. Text read here stays in the session record and local variables, is cleared when
// the watch finishes, and is never logged, persisted or transmitted.
// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// Why a watch stopped without an edit to check.
enum CorrectionDiscardReason: Error, Equatable {
    case notTrusted, focusChanged, secureField, readFailed, pasteNotAtCaret, tooLong
    case startMoved, endNotFound, endAmbiguous, spanChangedTooMuch, spanRemoved, timeout, cancelled

    /// Stops that forbid using text already read: the watch was cancelled, permission was withdrawn, or the field
    /// turned secure. Every other stop only means the field can no longer be followed.
    var forbidsCapturedText: Bool {
        self == .cancelled || self == .notTrusted || self == .secureField
    }

    /// Start failures that a field still catching up with the paste produces: it shows the old text or a read fails.
    /// Only these try the start again.
    var allowsStartRetry: Bool {
        self == .pasteNotAtCaret || self == .readFailed
    }
}

enum SpanContext: Equatable {
    /// The span touches the start (before) or end (after) of the document.
    case documentEdge
    case text([UInt16])

    var units: [UInt16] {
        if case .text(let units) = self { return units }
        return []
    }
}

struct CorrectionSpanRecord {
    var spanStart = 0
    var spanLength = 0
    var before = SpanContext.documentEdge
    var after = SpanContext.documentEdge
    var pasted: [UInt16] = []
}

/// A correction the user made to a pasted dictation: what was pasted and what the span reads now.
public struct CorrectionEdit: Equatable, Sendable {
    public let typed: String
    public let edited: String
    /// The speech result's correction id, which names the dictation's retained audio.
    public let correctionID: UInt64

    public init(typed: String, edited: String, correctionID: UInt64) {
        self.typed = typed
        self.edited = edited
        self.correctionID = correctionID
    }

    public static func == (lhs: CorrectionEdit, rhs: CorrectionEdit) -> Bool {
        DictionaryText.same(lhs.typed, rhs.typed) && DictionaryText.same(lhs.edited, rhs.edited)
            && lhs.correctionID == rhs.correctionID
    }
}

enum CorrectionPollOutcome: Equatable {
    case watching
    /// An edit unchanged for the quiet period: check it and keep watching.
    case settled(CorrectionEdit)
    /// The watch ended with an edit that was not checked yet.
    case finalize(CorrectionEdit)
    case discard(CorrectionDiscardReason)
}

/// One watched paste. Deterministic: time is passed in, and every read goes through the reader. Used from one
/// isolation domain only.
final class CorrectionWatchSession {
    static let contextUnits = 40
    static let maxGrowth = 200
    static let maxPastedUnits = 4097  // 4096 bytes of output plus the trailing space
    static let beginWindowLimit = 4200
    static let pollWindowLimit = 4600
    static let quietPeriod: TimeInterval = 1.5
    static let maxDuration: TimeInterval = 60
    /// Edits reported per paste; the last one ends the watch.
    static let maxChecks = 3

    private let reader: any TextFieldReading
    private let target: TextFieldTarget
    private let correctionID: UInt64
    private let startTime: TimeInterval
    private var typed: String
    private var lastSpan: [UInt16]
    private var lastChange: TimeInterval
    private var cancelled = false
    /// True once the watch was cancelled from elsewhere; safe to call from any thread.
    private let isCancelled: () -> Bool
    /// Live time for the deadline check before each read; nil uses the poll's time.
    private let clock: (() -> TimeInterval)?
    private var pollTime: TimeInterval
    /// The edited text from the last read inside the window.
    private var lastEdited: String
    /// The span last reported for checking, initially the paste itself.
    private var reported: [UInt16]
    private var reports = 0
    private var outcome: CorrectionPollOutcome?
    private(set) var record: CorrectionSpanRecord

    var isFinished: Bool { outcome != nil }

    private init(reader: any TextFieldReading, target: TextFieldTarget, typed: String, record: CorrectionSpanRecord,
                 correctionID: UInt64, now: TimeInterval, isCancelled: @escaping () -> Bool,
                 clock: (() -> TimeInterval)?) {
        self.isCancelled = isCancelled
        self.clock = clock
        pollTime = now
        lastEdited = typed
        self.reader = reader
        self.target = target
        self.typed = typed
        self.record = record
        self.correctionID = correctionID
        startTime = now
        lastChange = now
        lastSpan = record.pasted
        reported = record.pasted
    }

    /// Reads just after the paste: the pasted text must end exactly at an empty selection. Records the span and up
    /// to 40 units of context on each side. A no-break space counts as a space, in the paste as in the field. With
    /// `expectedStart`, the paste must also start there.
    static func begin(reader: any TextFieldReading, target: TextFieldTarget, pasted: String, correctionID: UInt64,
                      now: TimeInterval, expectedStart: Int? = nil, isCancelled: @escaping () -> Bool = { false },
                      clock: (() -> TimeInterval)? = nil) -> Result<CorrectionWatchSession, CorrectionDiscardReason> {
        let units = Array(foldingNoBreakSpaces(pasted).utf16)
        guard !units.isEmpty else { return .failure(.pasteNotAtCaret) }
        guard units.count <= maxPastedUnits else { return .failure(.tooLong) }
        let count: Int, selection: TextFieldRange, window: (text: String, units: [UInt16])
        let caret: Int, spanStart: Int
        do {
            count = try guardedRead(reader, target, isCancelled, { false }) { reader.characterCount(target) }
            selection = try guardedRead(reader, target, isCancelled, { false }) { reader.selectedRange(target) }
            guard count >= 0, selection.length == 0, selection.location >= units.count, selection.location <= count else {
                return .failure(.pasteNotAtCaret)
            }
            caret = selection.location
            spanStart = caret - units.count
            if let expectedStart, spanStart != expectedStart { return .failure(.pasteNotAtCaret) }
            let windowStart = max(0, spanStart - contextUnits)
            let windowEnd = min(count, caret + contextUnits)
            guard windowEnd - windowStart <= beginWindowLimit else { return .failure(.tooLong) }
            window = try guardedRead(reader, target, isCancelled, { false }) {
                read(reader: reader, target: target, from: windowStart, to: windowEnd)
            }
        } catch {
            return .failure(error)
        }
        let local = spanStart - max(0, spanStart - contextUnits)
        guard window.units[local..<local + units.count].elementsEqual(units) else { return .failure(.pasteNotAtCaret) }
        var record = CorrectionSpanRecord()
        record.spanStart = spanStart
        record.spanLength = units.count
        record.before = spanStart == 0 ? .documentEdge : .text(Array(window.units[..<local]))
        record.after = caret == count ? .documentEdge : .text(Array(window.units[(local + units.count)...]))
        record.pasted = units
        return .success(CorrectionWatchSession(reader: reader, target: target, typed: pasted, record: record,
                                               correctionID: correctionID, now: now, isCancelled: isCancelled,
                                               clock: clock))
    }

    /// Setting off, permission withdrawn, a new dictation, a dictionary change or quitting: discard without
    /// finalizing.
    func cancel() { cancelled = true }

    func poll(now: TimeInterval) -> CorrectionPollOutcome {
        if let outcome { return outcome }
        if cancelled || isCancelled() { return finish(.discard(.cancelled)) }
        pollTime = now
        // Past the 60 s window nothing is read again, however late the poll runs.
        if isExpired() { return finish(expire()) }
        let span: [UInt16]
        let edited: String
        do {
            (span, edited) = try locate()
        } catch .timeout {
            return finish(expire())
        } catch {
            return finish(end(error))
        }
        // The whole paste is gone, as when a chat field clears on send.
        if span.isEmpty { return finish(end(.spanRemoved)) }
        if span != lastSpan {
            lastSpan = span
            lastEdited = edited
            lastChange = now
        }
        if hasUncheckedEdit && now - lastChange >= Self.quietPeriod { return report() }
        if isExpired() { return finish(expire()) }
        return .watching
    }

    private func isExpired() -> Bool {
        (clock?() ?? pollTime) - startTime >= Self.maxDuration
    }

    /// The last edit read differs from the paste and from the last report.
    private var hasUncheckedEdit: Bool { lastSpan != record.pasted && lastSpan != reported }

    private var lastEdit: CorrectionEdit { CorrectionEdit(typed: typed, edited: lastEdited, correctionID: correctionID) }

    /// Reports the current edit for checking. The last allowed report ends the watch.
    private func report() -> CorrectionPollOutcome {
        reported = lastSpan
        reports += 1
        return reports >= Self.maxChecks ? finish(.finalize(lastEdit)) : .settled(lastEdit)
    }

    /// The watch can go no further. Unless the stop forbids it, an edit read earlier and not checked yet is
    /// finalized from memory; nothing new is read.
    private func end(_ reason: CorrectionDiscardReason) -> CorrectionPollOutcome {
        !reason.forbidsCapturedText && hasUncheckedEdit ? .finalize(lastEdit) : .discard(reason)
    }

    /// At the deadline: the same safety checks as before any read (metadata only; text is never requested past the
    /// deadline). A field that turned secure or lost permission is discarded; one that lost focus still finalizes
    /// text captured inside the window.
    private func expire() -> CorrectionPollOutcome {
        if cancelled || isCancelled() { return .discard(.cancelled) }
        return end(Self.safetyCheck(reader: reader, target: target) ?? .timeout)
    }

    /// Deterministic span tracking: the before context still sits right before the span (or the span starts the
    /// document), and the after context occurs exactly once from the span start on, within 200 units of growth or
    /// shrinkage (or the span runs to the end of the document).
    private func locate() throws(CorrectionDiscardReason) -> ([UInt16], String) {
        let (reader, target) = (self.reader, self.target)
        let count = try Self.guardedRead(reader, target, isCancelled, isExpired) { reader.characterCount(target) }
        let before = record.before.units, after = record.after.units
        guard count >= 0 else { throw .readFailed }
        guard count >= record.spanStart else { throw .startMoved }
        let windowStart = record.spanStart - before.count
        let windowEnd = min(count, record.spanStart + record.spanLength + Self.maxGrowth + after.count)
        guard windowEnd - windowStart <= Self.pollWindowLimit else { throw .tooLong }
        let window = try Self.guardedRead(reader, target, isCancelled, isExpired) {
            Self.read(reader: reader, target: target, from: windowStart, to: windowEnd)
        }
        let units = window.units
        guard units.count >= before.count, units[..<before.count].elementsEqual(before) else {
            throw .startMoved
        }

        let newLength: Int
        if record.after == .documentEdge {
            newLength = count - record.spanStart
        } else {
            var found: [Int] = []
            if units.count - after.count >= before.count {
                for start in before.count...(units.count - after.count)
                where units[start..<start + after.count].elementsEqual(after) {
                    found.append(start)
                    if found.count > 1 { throw .endAmbiguous }
                }
            }
            guard let end = found.first else { throw .endNotFound }
            newLength = end - before.count
        }
        guard abs(newLength - record.spanLength) <= Self.maxGrowth else { throw .spanChangedTooMuch }
        let range = NSRange(location: before.count, length: newLength)
        guard let stringRange = Range(range, in: window.text) else { throw .readFailed }
        let edited = String(window.text[stringRange])
        let span = Array(units[before.count..<before.count + newLength])
        guard Self.isValidUTF16(span), Array(edited.utf16) == span else { throw .readFailed }
        return (span, edited)
    }

    /// Every read is preceded by the safety check, so a field that turns secure or loses focus is never read again.
    /// Cancellation is checked immediately before the check and again before the read itself, so a cancel that lands
    /// during an in-flight Accessibility call stops the next one.
    private static func guardedRead<T>(_ reader: any TextFieldReading, _ target: TextFieldTarget,
                                       _ isCancelled: () -> Bool, _ isExpired: () -> Bool,
                                       _ read: () -> T?) throws(CorrectionDiscardReason) -> T {
        func stopIfNeeded() throws(CorrectionDiscardReason) {
            if isCancelled() { throw .cancelled }
            if isExpired() { throw .timeout }
        }
        try stopIfNeeded()
        if let reason = safetyCheck(reader: reader, target: target) { throw reason }
        try stopIfNeeded()
        guard let value = read() else { throw .readFailed }
        return value
    }

    private func finish(_ outcome: CorrectionPollOutcome) -> CorrectionPollOutcome {
        self.outcome = outcome
        record = CorrectionSpanRecord()
        lastSpan = []
        reported = []
        typed = ""
        lastEdited = ""
        return outcome
    }

    /// Before every read: permission, the same destination, and no secure field.
    static func safetyCheck(reader: any TextFieldReading, target: TextFieldTarget) -> CorrectionDiscardReason? {
        guard reader.isTrusted() else { return .notTrusted }
        switch reader.check(target) {
        case .ok: return nil
        case .focusChanged: return .focusChanged
        case .secure: return .secureField
        case .failed: return .readFailed
        }
    }

    /// Browsers show a trailing or repeated space as a no-break space and switch it back as the text changes, so
    /// every read counts it as a space.
    private static func read(reader: any TextFieldReading, target: TextFieldTarget, from start: Int,
                             to end: Int) -> (text: String, units: [UInt16])? {
        guard start >= 0, end >= start,
              let read = reader.string(target, range: TextFieldRange(location: start, length: end - start)) else {
            return nil
        }
        let text = foldingNoBreakSpaces(read)
        let units = Array(text.utf16)
        return units.count == end - start ? (text, units) : nil
    }

    /// U+00A0 becomes U+0020, one UTF-16 unit for another, so offsets are kept.
    private static func foldingNoBreakSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ", options: .literal)
    }

    static func isValidUTF16(_ units: [UInt16]) -> Bool {
        var iterator = units.makeIterator()
        var decoder = UTF16()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}

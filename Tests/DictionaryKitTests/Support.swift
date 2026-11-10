import Foundation
import Synchronization
import Testing
@testable import DictionaryKit

// Helpers shared by the dictionary tests. All text is invented.

func s(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

func entry(_ text: String, _ strength: Float = 1) -> DictionaryEntry { DictionaryEntry(text: text, strength: strength) }

/// Every single scalar a test needs, so encodability depends only on the case.
let testEncoder: BPEEncoder = {
    var pieces = ["<unk>", "▁"]
    pieces += "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#ïé'.,".unicodeScalars.map { String($0) }
    pieces += ["▁k", "ub", "er", "▁n", "ix", "os"]
    return BPEEncoder(pieces: pieces)
}()

func expectScalars(_ actual: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(s(actual) == s(expected), "Expected \(expected.debugDescription), got \(actual.debugDescription)",
            sourceLocation: sourceLocation)
}

/// Floats within one unit in the last place, as the vectors require.
func expectULP(_ actual: Float, _ expected: Float, sourceLocation: SourceLocation = #_sourceLocation) {
    let close = actual == expected
        || (actual.sign == expected.sign && actual.isFinite && expected.isFinite
            && (actual.bitPattern > expected.bitPattern ? actual.bitPattern - expected.bitPattern
                : expected.bitPattern - actual.bitPattern) <= 1)
    #expect(close, "Expected \(expected) within 1 ULP, got \(actual)", sourceLocation: sourceLocation)
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }

    var failure: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}

/// Logits of the size the decoder exposes, -100 everywhere except `values`.
func decisionLogits(_ values: [Int: Float]) -> [Float] {
    var logits = [Float](repeating: -100, count: 1030)
    for (index, value) in values { logits[index] = value }
    return logits
}

/// Waits on the main actor, letting delivered callbacks run, until `done` or the timeout.
@MainActor
func waitUntil(_ timeout: TimeInterval, _ done: () -> Bool = { false }) async {
    let end = ContinuousClock.now + .seconds(timeout)
    while !done() && ContinuousClock.now < end {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A text field held as UTF-16 units, as Accessibility reports it. Thread-safe, because the watcher reads it on its
/// own queue while a test edits it.
final class FakeTextFieldReader: TextFieldReading {
    private struct State {
        var units: [UInt16]
        var caret: Int
        var selectionLength = 0
        var trusted = true
        var focused = true
        var secure = false
        var failReads = false
        var supportsRangeReads = true
        var rangeReads: [TextFieldRange] = []
        var uncheckedReads = 0
        var captureCalls = 0
        var checks = 0
        var countReads = 0
        var checkedSinceRead = false
        var onCharacterCount: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>
    /// The field's handle, as the real reader would wrap an Accessibility element.
    private struct Field: Equatable, Sendable { let id = 7 }
    private let element = Field()

    init(_ text: String) {
        let units = Array(text.utf16)
        state = Mutex(State(units: units, caret: units.count))
    }

    private func read<T>(_ value: (State) -> T) -> T { state.withLock { value($0) } }
    private func write(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    var string: String { read { String(decoding: $0.units, as: UTF16.self) } }
    var caret: Int { get { read { $0.caret } } set { write { $0.caret = newValue } } }
    var selectionLength: Int { get { read { $0.selectionLength } } set { write { $0.selectionLength = newValue } } }
    var trusted: Bool { get { read { $0.trusted } } set { write { $0.trusted = newValue } } }
    var focused: Bool { get { read { $0.focused } } set { write { $0.focused = newValue } } }
    var secure: Bool { get { read { $0.secure } } set { write { $0.secure = newValue } } }
    var failReads: Bool { get { read { $0.failReads } } set { write { $0.failReads = newValue } } }
    var supportsRangeReads: Bool {
        get { read { $0.supportsRangeReads } }
        set { write { $0.supportsRangeReads = newValue } }
    }
    /// Runs inside the character-count request, as if during an in-flight Accessibility call.
    var onCharacterCount: (@Sendable () -> Void)? {
        get { read { $0.onCharacterCount } }
        set { write { $0.onCharacterCount = newValue } }
    }
    var rangeReads: [TextFieldRange] { read { $0.rangeReads } }
    /// Reads not preceded by a safety check since the previous read.
    var uncheckedReads: Int { read { $0.uncheckedReads } }
    var captureCalls: Int { read { $0.captureCalls } }
    var checks: Int { read { $0.checks } }
    var countReads: Int { read { $0.countReads } }

    func paste(_ text: String) {
        write { state in
            state.units.insert(contentsOf: text.utf16, at: state.caret)
            state.caret += text.utf16.count
        }
    }

    func append(_ text: String) { write { $0.units.append(contentsOf: text.utf16) } }

    func insert(_ text: String, at offset: Int) { write { $0.units.insert(contentsOf: text.utf16, at: offset) } }

    func replace(_ old: String, with new: String) { replace(old, with: new, last: false) }

    func replaceLast(_ old: String, with new: String) { replace(old, with: new, last: true) }

    private func replace(_ old: String, with new: String, last: Bool) {
        write { state in
            let needle = Array(old.utf16)
            let starts = needle.isEmpty || needle.count > state.units.count ? [] : (0...(state.units.count - needle.count))
                .filter { Array(state.units[$0..<$0 + needle.count]) == needle }
            guard let start = last ? starts.last : starts.first else {
                Issue.record("Fake text has no \(old)")
                return
            }
            state.units.replaceSubrange(start..<start + needle.count, with: new.utf16)
        }
    }

    func isTrusted() -> Bool { read { $0.trusted } }

    func captureFocusedTextField() -> TextFieldTarget? {
        let capturable = state.withLock { state in
            state.captureCalls += 1
            return state.trusted && state.focused && !state.secure
        }
        return capturable ? TextFieldTarget(pid: 4242, element: element) : nil
    }

    func check(_ target: TextFieldTarget) -> TextFieldCheck {
        state.withLock { state in
            state.checkedSinceRead = true
            state.checks += 1
            guard state.focused, target.pid == 4242, target.element as? Field == element else { return .focusChanged }
            return state.secure ? .secure : .ok
        }
    }

    private static func noteRead(_ state: inout State) {
        if !state.checkedSinceRead { state.uncheckedReads += 1 }
        state.checkedSinceRead = false
    }

    func characterCount(_ target: TextFieldTarget) -> Int? {
        let hook = state.withLock { state in
            Self.noteRead(&state)
            state.countReads += 1
            return state.onCharacterCount
        }
        hook?()
        return read { $0.failReads ? nil : $0.units.count }
    }

    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? {
        state.withLock { state in
            Self.noteRead(&state)
            return state.failReads ? nil : TextFieldRange(location: state.caret, length: state.selectionLength)
        }
    }

    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? {
        state.withLock { state in
            Self.noteRead(&state)
            guard state.supportsRangeReads, !state.failReads, range.location >= 0, range.length >= 0,
                  range.location + range.length <= state.units.count else { return nil }
            state.rangeReads.append(range)
            let slice = Array(state.units[range.location..<range.location + range.length])
            return String(utf16CodeUnits: slice, count: slice.count)
        }
    }
}

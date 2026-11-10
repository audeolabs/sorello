import DictionaryKit
import Foundation
import Synchronization

// A text field in another app, for the probe and the inserter. All text is invented.

/// The element handle inside a fake target: a small Sendable value, as the contract asks of test fakes.
struct FakeElement: Sendable, Equatable {
    let id: Int
}

/// A text field in another app, read the way `TextFieldReading` reads one. Ported from the reference fake, with its
/// state behind a lock so the probe can read it from its own queue.
final class FakeTextField: TextFieldReading {
    struct State {
        var units: [UInt16]
        var caret: Int
        var selectionLength = 0
        var trusted = true
        var focused = true
        var secure = false
        var failReads = false
        var supportsRangeReads = true
        /// The element that has focus now; the captured field is element 1.
        var focusedElement = 1
        var rangeReads: [TextFieldRange] = []
        /// Reads not preceded by a safety check since the previous read.
        var uncheckedReads = 0
        var captureCalls = 0
        var calls: [String] = []
        var checkedSinceRead = false
        /// Runs inside the character-count request, as if during an in-flight Accessibility call.
        var onCharacterCount: (@Sendable () -> Void)?
    }

    static let pid: Int32 = 4242
    let state: Mutex<State>

    init(_ text: String) {
        let units = Array(text.utf16)
        state = Mutex(State(units: units, caret: units.count))
    }

    func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    var units: [UInt16] { state.withLock { $0.units } }

    /// Inserts `text` at the caret, replacing the selection, as a paste would.
    func paste(_ text: String) {
        update { state in
            state.units.replaceSubrange(state.caret..<state.caret + state.selectionLength, with: text.utf16)
            state.caret += text.utf16.count
            state.selectionLength = 0
        }
    }

    func isTrusted() -> Bool {
        state.withLock { state in
            state.calls.append("isTrusted")
            return state.trusted
        }
    }

    func captureFocusedTextField() -> TextFieldTarget? {
        state.withLock { state in
            state.calls.append("capture")
            state.captureCalls += 1
            guard state.trusted, state.focused, !state.secure else { return nil }
            return TextFieldTarget(pid: Self.pid, element: FakeElement(id: state.focusedElement))
        }
    }

    func check(_ target: TextFieldTarget) -> TextFieldCheck {
        state.withLock { state in
            state.calls.append("check")
            state.checkedSinceRead = true
            guard let element = target.element as? FakeElement else { return .failed }
            guard state.focused, target.pid == Self.pid, element.id == state.focusedElement else { return .focusChanged }
            return state.secure ? .secure : .ok
        }
    }

    private func noteRead(_ state: inout State, _ name: String) {
        state.calls.append(name)
        if !state.checkedSinceRead { state.uncheckedReads += 1 }
        state.checkedSinceRead = false
    }

    func characterCount(_ target: TextFieldTarget) -> Int? {
        let hook = state.withLock { state in
            noteRead(&state, "characterCount")
            return state.onCharacterCount
        }
        hook?()
        return state.withLock { $0.failReads ? nil : $0.units.count }
    }

    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange? {
        state.withLock { state in
            noteRead(&state, "selectedRange")
            return state.failReads ? nil : TextFieldRange(location: state.caret, length: state.selectionLength)
        }
    }

    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String? {
        state.withLock { state in
            noteRead(&state, "string")
            guard state.supportsRangeReads, !state.failReads, range.location >= 0, range.length >= 0,
                  range.location + range.length <= state.units.count else { return nil }
            state.rangeReads.append(range)
            let slice = Array(state.units[range.location..<range.location + range.length])
            return String(decoding: slice, as: UTF16.self)
        }
    }
}

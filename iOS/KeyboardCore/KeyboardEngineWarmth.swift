#if SORELLO_KEYBOARD_DICTATION
import Foundation

/// Whether an in-keyboard attempt starts warm or cold (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Record):
/// warm only with an engine loaded, prepared successfully, and not on its way out. `KeyboardSpeech` keeps it beside its
/// engine, which it names by identity. Pure.
struct KeyboardEngineWarmth: Equatable, Sendable {
    /// The engine loaded now.
    private(set) var engine: ObjectIdentifier?
    private var prepared = false

    /// An attempt that uses the engine now starts warm.
    var isWarm: Bool { engine != nil && prepared }

    /// A new engine was made: loaded, not prepared.
    mutating func made(_ engine: ObjectIdentifier) {
        self.engine = engine
        prepared = false
    }

    /// `engine` prepared successfully; nothing if it is not the one loaded now.
    mutating func prepared(_ engine: ObjectIdentifier) {
        if self.engine == engine { prepared = true }
    }

    /// A release of `engine` is queued: from now on a tap is cold, though the engine stays until its work has drained.
    /// Nothing if another engine is loaded now.
    mutating func releaseRequested(_ engine: ObjectIdentifier?) {
        if self.engine == engine { prepared = false }
    }

    /// The queued release of `engine` happened: true if it was the one loaded, which is now gone. One made since stays,
    /// as warm or cold as it was.
    @discardableResult
    mutating func released(_ engine: ObjectIdentifier?) -> Bool {
        guard let engine, self.engine == engine else { return false }
        self.engine = nil
        prepared = false
        return true
    }
}
#endif

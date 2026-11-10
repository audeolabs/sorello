import DictationCore
import DictionaryKit
import MacPlatform
import SpeechEngine

// What the correction coordinator works through: the watch on the pasted text and the engine's retained audio. Small
// protocols, so the coordinator's decisions are tested with fakes and no Accessibility.

/// A paste bound to one watch. Opaque outside the watcher that made it.
nonisolated struct WatchAnchor: Sendable {
    /// The watch it belongs to; stale once anything cancels corrections.
    let generation: UInt64
    let value: any Sendable
}

/// The correction watch (`CorrectionWatcher`, docs/dictionary/DESIGN.md, section 3.5).
nonisolated protocol CorrectionWatching: Sendable {
    /// Moves on with every cancel, anchor and claim.
    var currentGeneration: UInt64 { get }
    /// Binds the field the inserter read to a new watch, if nothing cancelled corrections since `expected`.
    func anchor(_ field: PreparedField, expecting expected: UInt64) -> WatchAnchor?
    /// Begins following the paste.
    func start(_ anchor: WatchAnchor, pasted: String, correctionID: UInt64)
    /// Ends the current watch without finalizing; what it read is dropped.
    func cancel()
    /// Ends watch `watch` to use a result for it; false, changing nothing, when it is no longer current.
    func claim(_ watch: UInt64) -> Bool
}

/// The real watcher, which reads the destination field through Accessibility.
nonisolated struct FieldCorrectionWatcher: CorrectionWatching {
    let watcher: CorrectionWatcher

    var currentGeneration: UInt64 { watcher.currentGeneration }

    func anchor(_ field: PreparedField, expecting expected: UInt64) -> WatchAnchor? {
        watcher.anchor(target: field.target, insertionPoint: field.selection.location, expecting: expected)
            .map { WatchAnchor(generation: $0.generation, value: $0) }
    }

    func start(_ anchor: WatchAnchor, pasted: String, correctionID: UInt64) {
        guard let anchor = anchor.value as? CorrectionAnchor else { return }
        watcher.start(anchor, pasted: pasted, correctionID: correctionID)
    }

    func cancel() { watcher.cancel() }

    func claim(_ watch: UInt64) -> Bool { watcher.claim(watch) }
}

/// The engine's side of a suggestion: checking an edit against the retained audio, and letting the audio go.
nonisolated protocol CorrectionEngine: Sendable {
    /// Registers a check now, cancelling any older one, and returns the work that finds the suggestion: nil when
    /// there is none or the check was overtaken. With `isLast` the audio is released when the work ends.
    func correctionCheck(typed: String, edited: String, correctionID: UInt64, ignore: Set<DictionaryKey>,
                         isLast: Bool) -> @Sendable () async -> DictionarySuggestion?
    /// Releases one dictation's audio, never a newer one's.
    func releaseCorrection(_ correctionID: UInt64)
    /// Releases whatever audio is kept and stops a running check.
    func discardCorrection()
}

extension SpeechEngine: CorrectionEngine {
    nonisolated func correctionCheck(typed: String, edited: String, correctionID: UInt64,
                                     ignore: Set<DictionaryKey>,
                                     isLast: Bool) -> @Sendable () async -> DictionarySuggestion? {
        let check = beginCorrectionCheck()
        return {
            await self.suggestCorrection(typed: typed, edited: edited, correctionID: correctionID, ignore: ignore,
                                         isLast: isLast, check: check)
        }
    }
}

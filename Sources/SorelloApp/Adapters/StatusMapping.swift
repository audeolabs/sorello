import DictationCore
import DictionaryKit
import MacPlatform
import Persistence
import SorelloUI
import SpeechEngine

// The windows' words for the app's health and for refused edits. The state line, the sidebar's foot and General all
// read the same `AppStatus`, built here from what the session and the adapters report.

extension ModelStatus {
    /// The engine's readiness as the windows show it.
    init(_ readiness: EngineReadiness) {
        switch readiness {
        case .preparing: self = .preparing
        case .ready: self = .ready
        // This app cannot download its model yet, so a missing model is one there is no way to get.
        case .failed(.modelMissing): self = .notDownloaded(.unavailable)
        case .failed(.modelCorrupt): self = .failed(.damaged)
        case .failed(.loadFailed): self = .failed(.couldNotLoad)
        }
    }
}

extension ModelHardware {
    /// Where the engine runs the encoder, as General says it.
    init(_ compute: SpeechCompute) {
        switch compute {
        case .neuralEngine: self = .neuralEngine
        case .cpu: self = .processor
        }
    }
}

extension MicrophoneStatus {
    /// Microphone access as the windows show it. Never asked is not a problem: the first dictation asks.
    init(_ access: MicrophoneAccess) {
        switch access {
        case .unknown: self = .notDetermined
        case .granted: self = .granted
        case .denied: self = .denied
        }
    }
}

extension AppStatus {
    /// The status line's inputs: the engine and microphone as the session holds them, Accessibility as last read, and
    /// whether secure input has paused the shortcuts.
    init(session: SessionState, accessibilityTrusted: Bool, shortcuts: ShortcutMonitor.Status) {
        self.init(model: ModelStatus(session.engine), microphone: MicrophoneStatus(session.microphone),
                  accessibility: accessibilityTrusted ? .granted : .missing,
                  shortcutsPaused: shortcuts == .pausedBySecureInput)
    }
}

extension DictionaryProblem {
    /// A refused dictionary change in the Dictionary screen's words. Every message is content-free.
    init(_ error: DictionaryChangeError) {
        switch error {
        case .noVocabulary: self = .needsModel
        case .invalid(let entry): self.init(entry)
        case .full: self = .full(capacity: DictionaryValidation.capacity)
        case .appsFull: self = .appsFull(capacity: DictionaryAppScopes.appCapacity)
        case .invalidKey: self = .unencodable
        // The screen registers an app before it limits a word to it and never adds to the ignore list, so these two
        // arrive only if the file changed under it: the change was not made.
        case .unknownApp, .ignoreFull, .notSaved: self = .notSaved
        }
    }

    /// A word that cannot be an entry, in the Dictionary screen's words.
    init(_ error: DictionaryEntryError) {
        switch error {
        case .empty: self = .empty
        case .tooManyWords: self = .tooManyWords(limit: DictionaryValidation.maxWords)
        case .tooLong: self = .tooLong(limit: DictionaryValidation.maxScalars)
        case .noLetter: self = .noLetter
        case .unencodable: self = .unencodable
        // The screen offers only the presets, all valid; a stored strength out of range is refused as unsaved.
        case .invalidStrength: self = .notSaved
        }
    }
}

extension MacroProblem {
    /// A refused macro change in the Macros screen's words.
    init(_ error: MacroStoreError) {
        switch error {
        case .emptyCommand: self = .emptyPhrase
        case .duplicateCommand: self = .duplicatePhrase
        // The macro was deleted meanwhile, or the file could not be written: either way nothing was saved.
        case .notFound, .saveFailed: self = .notSaved
        }
    }
}

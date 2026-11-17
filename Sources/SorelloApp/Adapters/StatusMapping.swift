import DictationCore
import DictionaryKit
import MacPlatform
import Persistence
import SorelloUI
import SpeechEngine

// The windows' words for the app's health and for refused edits. The state line, the sidebar's foot and General all
// read the same `AppStatus`, built here from what the session and the adapters report.

extension ModelStatus {
    /// The engine's readiness, and when the model is missing the download's state, as the windows show them. A copy
    /// with no download (nil) has no way to get the model.
    init(_ readiness: EngineReadiness, download: ModelDownloadState? = nil, size: Int64 = 0) {
        switch readiness {
        case .preparing: self = .preparing
        case .ready: self = .ready
        case .failed(.modelCorrupt): self = .failed(.damaged)
        case .failed(.loadFailed): self = .failed(.couldNotLoad)
        case .failed(.modelMissing):
            switch download {
            case .absent: self = .notDownloaded(.notStarted(size: size))
            case .downloading(let received): self = .notDownloaded(.downloading(received: received, size: size))
            case .failed(let failure): self = .notDownloaded(.failed(ModelDownloadProblem(failure), size: size))
            // The model has just arrived and the engine is about to look for it.
            case .installed: self = .preparing
            case .unavailable, nil: self = .notDownloaded(.unavailable)
            }
        }
    }
}

extension ModelDownloadProblem {
    /// Why the download stopped, in the windows' words.
    init(_ failure: ModelDownloadFailure) {
        switch failure {
        case .connection: self = .connection
        case .server: self = .server
        case .check: self = .check
        case .disk: self = .disk
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
    /// The status line's inputs: the engine and microphone as the session holds them, the model's download, its size,
    /// Accessibility as last read, and whether secure input has paused the shortcuts.
    init(session: SessionState, download: ModelDownloadState? = nil, modelSize: Int64 = 0, accessibilityTrusted: Bool,
         shortcuts: ShortcutMonitor.Status) {
        self.init(model: ModelStatus(session.engine, download: download, size: modelSize),
                  microphone: MicrophoneStatus(session.microphone),
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
        case .soundsLike(let spelling): self.init(spelling)
        case .spellingOfAnotherWord: self = .wordIsASpelling
        }
    }

    /// Spellings that cannot be saved, in the Dictionary screen's words (DESIGN §3.7).
    init(_ error: SoundsLikeError) {
        switch error {
        case .invalid(.tooManyWords): self = .spellingTooManyWords(limit: DictionaryValidation.maxWords)
        case .invalid(.tooLong): self = .spellingTooLong(limit: DictionaryValidation.maxScalars)
        case .invalid(.noLetter): self = .spellingNoLetter
        case .invalid(.unencodable): self = .spellingUnencodable
        case .tooMany: self = .tooManySpellings(limit: SoundsLike.maxSpellings)
        case .sameAsWord: self = .spellingIsTheWord
        case .taken: self = .spellingTaken
        // The screen splits what is typed at commas and drops empty pieces, and spellings have no strength, so these
        // arrive only if the dictionary changed under it: the change was not made.
        case .invalid(.empty), .invalid(.invalidStrength), .comma: self = .notSaved
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

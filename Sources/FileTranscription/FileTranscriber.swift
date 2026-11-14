import DictationCore
import Foundation
import SpeechEngine
import TextRules

// Transcribing one file (ARCHITECTURE.md, section 5, "Transcribing a file"). The Transcribe File window and the
// `sorello` command both take this one path, so the same file with the same dictionary and rules gives the same text
// in both.

/// How a file's transcription failed (ARCHITECTURE.md, section 5, "Transcribing a file"). Carries nothing the file
/// holds.
public enum FileTranscriptionFailure: Error, Sendable, Equatable {
    /// The file is not there, is a directory, or may not be read.
    case cannotOpen
    /// `AVAudioFile` cannot read it: a format Sorello does not read, no soundtrack, or damage part way through.
    case unreadable
    /// The model is not downloaded.
    case modelMissing
    /// No build in the pin fits this Mac.
    case noModelForThisMac
    /// The model could not be loaded: it is damaged, or loading it failed.
    case modelUnavailable
    /// The transcription failed.
    case failed
    /// The task was cancelled.
    case cancelled
}

/// What a running transcription reports.
public enum FileTranscriptionProgress: Sendable, Equatable {
    /// The model is not ready yet; the file waits for it.
    case preparingModel
    /// Seconds of the file's audio read so far, never more than `length`, and the file's length in seconds.
    case transcribing(read: TimeInterval, length: TimeInterval)
}

/// Turns one file into text. The window's binding and the command both use it; tests fake it.
public protocol FileTranscribing: Sendable {
    /// `rules`: the user's text rules to apply, or nil for the transcript as heard. `progress` may be called from any
    /// thread. Cancelling the calling task cancels it.
    func transcribe(_ file: URL, rules: TextRuleOptions?,
                    progress: @escaping @Sendable (FileTranscriptionProgress) -> Void)
        async throws(FileTranscriptionFailure) -> String
}

/// The real one, over the speech engine.
///
/// The engine reads the file and transcribes it with its dictionary's words that apply everywhere; the transcript
/// then goes through `rules` as a Run Log retry's does: in plain style, with no text around a cursor, so spoken
/// numbers, spoken delimiters and macros apply and a trailing "press enter" is removed when that rule is on. Nothing
/// is pasted, no key is pressed, and nothing is kept. A failure part way through gives no text at all.
public struct FileTranscriber: FileTranscribing {
    private let speech: any FileSpeech
    private let modelFitsThisMac: Bool

    /// `engine`: the app's engine, or one the command made as the app makes its own. Its dictionary closure decides
    /// the words (the command passes an empty snapshot for --no-dictionary). `modelFitsThisMac`: whether the pin has a
    /// build for this Mac (`PinnedModel.build != nil`), so a missing model is told from no model at all.
    public init(engine: SpeechEngine, modelFitsThisMac: Bool) {
        self.init(speech: engine, modelFitsThisMac: modelFitsThisMac)
    }

    /// Over any engine that transcribes files, so tests can stand in for the engine.
    init(speech: any FileSpeech, modelFitsThisMac: Bool) {
        self.speech = speech
        self.modelFitsThisMac = modelFitsThisMac
    }

    public func transcribe(_ file: URL, rules: TextRuleOptions?,
                           progress: @escaping @Sendable (FileTranscriptionProgress) -> Void)
        async throws(FileTranscriptionFailure) -> String {
        let heard: String
        do {
            heard = try await speech.transcribe(file: file) { report in
                switch report {
                case .preparingModel: progress(.preparingModel)
                case .transcribing(let read, let length): progress(.transcribing(read: read, length: length))
                }
            }
        } catch {
            throw failure(error)
        }
        guard let rules else { return heard }
        return DictationRules.process(heard, options: rules, promptStyle: false).text
    }

    private func failure(_ failure: FileSpeechFailure) -> FileTranscriptionFailure {
        switch failure {
        case .cannotOpen: .cannotOpen
        case .unreadable: .unreadable
        case .engineUnavailable(.modelMissing): modelFitsThisMac ? .modelMissing : .noModelForThisMac
        case .engineUnavailable(.modelCorrupt), .engineUnavailable(.loadFailed): .modelUnavailable
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

/// What `FileTranscriber` needs of the engine: a file's transcript, before any text rule.
protocol FileSpeech: Sendable {
    func transcribe(file: URL, progress: @escaping @Sendable (FileSpeechProgress) -> Void)
        async throws(FileSpeechFailure) -> String
}

extension SpeechEngine: FileSpeech {}

import DictationCore
import SpeechEngine

/// The speech engine as the app uses it: the session's port, Run Log retries, the audio kept for suggestions, and
/// where it runs.
nonisolated protocol AppSpeech: SpeechTranscribing, CorrectionEngine {
    /// Where the encoder runs, chosen when the engine was made; General says it.
    var compute: SpeechCompute { get }
    /// Transcribes a whole recording again, as a Run Log retry does, before any text rule.
    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String
}

extension SpeechEngine: AppSpeech {}

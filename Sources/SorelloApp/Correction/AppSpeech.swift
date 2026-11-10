import DictationCore
import SpeechEngine

/// The speech engine as the app uses it: the session's port, Run Log retries, and the audio kept for suggestions.
nonisolated protocol AppSpeech: SpeechTranscribing, CorrectionEngine {
    /// Transcribes a whole recording again, as a Run Log retry does, before any text rule.
    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String
}

extension SpeechEngine: AppSpeech {}

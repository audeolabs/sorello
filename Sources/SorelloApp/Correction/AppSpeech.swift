import DictationCore
import DictionaryKit
import Foundation
import SpeechEngine

/// The speech engine as the app uses it: the session's port, Run Log retries, the audio kept for suggestions, and
/// where it runs.
nonisolated protocol AppSpeech: SpeechTranscribing, CorrectionEngine {
    /// Where the encoder runs, chosen when the engine was made; General says it.
    var compute: SpeechCompute { get }
    /// Transcribes a whole recording again, as a Run Log retry does, before any text rule.
    func transcribe(_ samples: [Float], appBundleID: String?) async throws(SpeechFailure) -> String
}

extension SpeechEngine: AppSpeech {
    /// The engine for an app described by `info`: `model`, the build the app's pin lists for this Mac, looked for
    /// again at each preparation. A copy with no pin, run from a build tree with a model given on the command line,
    /// loads that model directly, keeping its stable copy in `store`.
    nonisolated static func forApp(_ info: AppInfo, model: PinnedModel?, store: URL, compute: SpeechCompute,
                                   dictionary: @escaping @Sendable (String?) -> DictionarySnapshot) -> SpeechEngine {
        guard let model else {
            return SpeechEngine(modelDirectory: info.modelDirectory, storeDirectory: store, compute: compute,
                                dictionary: dictionary)
        }
        return SpeechEngine(model: model, compute: compute, dictionary: dictionary)
    }
}

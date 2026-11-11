import DictationCore
import Foundation
import Persistence
import SorelloUI
import TextRules

// The values the session reads from the rest of the app: its settings, the text rules frozen for one dictation, and
// the level feed the pill draws the voice from (ARCHITECTURE.md, sections 3 and 4).

/// The user's text rules as they were when a dictation started, over `DictationRules`. A value: editing a macro or a
/// setting while the dictation waits changes nothing for it.
nonisolated struct TextRulesSnapshot: TranscriptProcessing, Equatable {
    /// The rules this snapshot applies.
    let options: TextRuleOptions

    init(options: TextRuleOptions) {
        self.options = options
    }

    /// The rules the settings and macros say now.
    @MainActor
    init(settings: SettingsStore, macros: [VoiceMacro]) {
        options = TextRuleOptions(macros: macros, pressEnterCommand: settings.pressEnterCommand,
                                  spokenNumbers: settings.spokenNumbers, spokenDelimiters: settings.spokenDelimiters,
                                  promptTag: settings.promptTag)
    }

    func process(_ transcript: String, style: DictationStyle, context: InsertionContext?) -> ProcessedDictation {
        let result = DictationRules.process(transcript, options: options, promptStyle: style == .prompt,
                                            before: context?.before, after: context?.after)
        return ProcessedDictation(heard: result.heard, text: result.text, pressEnter: result.pressEnter,
                                  usedMacro: result.usedMacro, addedPromptTag: result.addedPromptTag)
    }
}

extension SessionSettings {
    /// What the session reads for each event. Audio is kept for a correction suggestion only when suggestions are on,
    /// the dictionary can take a word and Accessibility lets the pasted text be watched (docs/dictionary/DESIGN.md,
    /// section 3.4).
    @MainActor
    init(settings: SettingsStore, dictionaryEditable: Bool, accessibilityTrusted: Bool) {
        self.init(doubleTap: settings.doubleTap, restoreClipboard: settings.restoreClipboard,
                  microphoneID: settings.microphoneID,
                  retainForCorrection: settings.correctionSuggestions && dictionaryEditable && accessibilityTrusted)
    }
}

/// The session's `LevelSink` over the pill's `LevelFeed`: a dictation's id is the feed's capture number, so the feed's
/// newest-capture rule is the port's newest-dictation rule.
nonisolated struct LevelFeedSink: LevelSink {
    let feed: LevelFeed

    func heard(_ samples: [Float], at time: TimeInterval, dictation: DictationID) {
        feed.heard(samples, at: time, capture: dictation.rawValue)
    }

    func captureEnded(dictation: DictationID) {
        feed.captureEnded(capture: dictation.rawValue)
    }
}

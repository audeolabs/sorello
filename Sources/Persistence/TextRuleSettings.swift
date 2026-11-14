import Foundation
import TextRules

extension TextRuleOptions {
    /// The text rules the settings and macros say now. The app's dictations, its Run Log retry and a file's
    /// transcription all build their rules here, so the same settings always mean the same rules.
    @MainActor
    public init(settings: SettingsStore, macros: [VoiceMacro]) {
        self.init(macros: macros, pressEnterCommand: settings.pressEnterCommand, spokenNumbers: settings.spokenNumbers,
                  spokenDelimiters: settings.spokenDelimiters, promptTag: settings.promptTag)
    }
}

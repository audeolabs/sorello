import Foundation

// Invented values for previews and snapshots. Nothing here is anyone's dictation, dictionary or device: the
// sentences are pangrams, the words are made up, and the date is fixed so pictures do not depend on the clock.

/// The moment every sample is measured from: Wednesday 11 November 2026, 15:30 UTC.
nonisolated let sampleNow = Date(timeIntervalSince1970: 1_794_411_000)

/// A fixed calendar and locale, so sample times read the same on every Mac.
nonisolated let sampleCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    return calendar
}()
nonisolated let sampleLocale = Locale(identifier: "en_US")

/// Sample statuses.
public extension AppStatus {
    /// Everything ready.
    static let sampleReady = AppStatus(model: .ready, microphone: .granted, accessibility: .granted)
}

/// Sample menu panels.
public extension MenuPanelModel {
    static func sample(status: AppStatus = .sampleReady, lastDictation: String? = "Sphinx of black quartz, judge my vow. The five boxing wizards jump quickly over the lazy dog.") -> MenuPanelModel {
        MenuPanelModel(appName: "Sorello", status: status,
                       shortcuts: [.holdToTalk: .function,
                                   .tapToToggle: KeyCombo(modifiers: [.control(.either), .option(.either)],
                                                          key: KeyName(label: "Space"))],
                       lastDictation: lastDictation)
    }
}

/// Sample menus for the menu-bar item.
public extension StatusMenuModel {
    static func sample(status: AppStatus = .sampleReady, lastDictation: String? = "Sphinx of black quartz, judge my vow. The five boxing wizards jump quickly over the lazy dog.") -> StatusMenuModel {
        StatusMenuModel(appName: "Sorello", status: status,
                        shortcuts: [.holdToTalk: .function,
                                    .tapToToggle: KeyCombo(modifiers: [.control(.either), .option(.either)],
                                                           key: KeyName(label: "Space"))],
                        lastDictation: lastDictation)
    }
}

/// A sample General screen.
public extension GeneralModel {
    static func sample(status: AppStatus = .sampleReady) -> GeneralModel {
        GeneralModel(modelName: "kea-b-0.1", status: status,
                     microphones: [MicrophoneOption(id: "sample-builtin", name: "Built-in Microphone"),
                                   MicrophoneOption(id: "sample-headset", name: "Sample Headset")],
                     selectedMicrophoneID: nil, defaultMicrophoneName: "Built-in Microphone",
                     toggles: [.launchAtLogin: true, .restoreClipboard: true, .spokenNumbers: true,
                               .spokenDelimiters: true, .pressEnter: true, .correctionSuggestions: true,
                               .keepRunLog: true])
    }
}

/// A sample Shortcuts screen; `recording` shows a recorder listening and a refusal.
public extension ShortcutsModel {
    static func sample(recording: Bool = false) -> ShortcutsModel {
        ShortcutsModel(
            recorders: [
                .holdToTalk: ShortcutRecorderState(keys: .function),
                .tapToToggle: ShortcutRecorderState(keys: KeyCombo(modifiers: [.control(.either), .option(.either)],
                                                                   key: KeyName(label: "Space")),
                                                    isRecording: recording),
                .pasteAgain: ShortcutRecorderState(
                    keys: recording ? KeyCombo(modifiers: [.command(.left), .command(.right), .option(.left),
                                                           .option(.right), .shift(.left)]) : nil,
                    refusal: recording ? .alreadyUsed(by: .holdToTalk) : nil),
            ],
            promptModeEnabled: true, promptTag: "[dictated]")
    }
}

/// Sample dictionaries.
public extension DictionaryModel {
    static let sampleApps = [AppLimit(id: "com.example.notes", name: "Notes"),
                             AppLimit(id: "com.example.terminal", name: "Terminal")]

    static func sample() -> DictionaryModel {
        DictionaryModel(
            words: [
                DictionaryWord(id: "quorvex", text: "Quorvex", strength: 2),
                DictionaryWord(id: "brindlemoor", text: "Brindlemoor", strength: 1),
                DictionaryWord(id: "zentarion api", text: "Zentarion API", strength: 2.83, apps: [sampleApps[1]]),
                DictionaryWord(id: "kestrelline", text: "Kestrelline", strength: 1.41,
                               apps: [sampleApps[0], sampleApps[1]]),
                DictionaryWord(id: "orrin fieldwork", text: "Orrin Fieldwork", strength: 4),
            ],
            ignored: [IgnoredWord(id: "vexel", text: "vexel"), IgnoredWord(id: "tamberlo", text: "Tamberlo")],
            knownApps: sampleApps)
    }

    /// The add field holding something the dictionary refuses.
    static func sampleRefusing() -> DictionaryModel {
        let model = sample()
        model.draft = DictionaryDraft(text: "1234", strength: 2)
        model.actions = DictionaryActions(validate: { $0.isEmpty ? .empty : .noLetter })
        return model
    }

    /// Without the speech model nothing can be changed.
    static func sampleNeedsModel() -> DictionaryModel {
        let model = sample()
        model.canEdit = false
        return model
    }

    static func sampleEmpty() -> DictionaryModel {
        DictionaryModel(words: [], ignored: [], knownApps: [])
    }
}

/// A sample Macros screen; `editing` opens one macro in the editor.
public extension MacrosModel {
    static func sample(editing: Bool = false) -> MacrosModel {
        let macros = [
            MacroItem(id: "1", phrase: "sample sign-off", text: "With thanks,\nA. Sample"),
            MacroItem(id: "2", phrase: "example address", text: "1 Example Street, Sampletown"),
            MacroItem(id: "3", phrase: "pangram please", text: "Pack my box with five dozen liquor jugs."),
        ]
        return MacrosModel(macros: macros,
                           editing: editing ? MacroDraft(id: "2", phrase: "example address", text: "") : nil,
                           actions: MacrosActions(validate: { phrase, _, id in
                               macros.contains { $0.phrase == phrase && $0.id != id } ? .duplicatePhrase : nil
                           }))
    }
}

/// A sample Run Log with an entry of every kind.
public extension RunLogModel {
    static func sample() -> RunLogModel {
        RunLogModel(
            items: [
                RunLogItem(id: "6", date: sampleNow.addingTimeInterval(-20), heard: "",
                           text: "Sphinx of black quartz, judge my vow.", outcome: .inserted, duration: 3),
                RunLogItem(id: "5", date: sampleNow.addingTimeInterval(-7 * 60), heard: "press enter", text: "",
                           outcome: .inserted, duration: 1),
                RunLogItem(id: "4", date: sampleNow.addingTimeInterval(-48 * 60), heard: "",
                           text: "The five boxing wizards jump quickly, and then they jump again, more slowly, because boxing wizards tire as the afternoon wears on.",
                           outcome: .leftOnClipboard, duration: 9),
                RunLogItem(id: "3", date: sampleNow.addingTimeInterval(-3 * 3600), heard: "", text: "",
                           outcome: .transcriptionFailed, duration: 6),
                RunLogItem(id: "2", date: sampleNow.addingTimeInterval(-26 * 3600), heard: "",
                           text: "How vexingly quick daft zebras jump.", outcome: .insertionFailed, duration: 4),
                RunLogItem(id: "1", date: sampleNow.addingTimeInterval(-9 * 86400), heard: "",
                           text: "Pack my box with five dozen liquor jugs.", outcome: .inserted, duration: 5),
            ],
            playingID: "6", retryingIDs: ["2"], referenceDate: sampleNow, calendar: sampleCalendar,
            locale: sampleLocale)
    }
}

/// A sample About screen.
public extension AboutModel {
    static func sample() -> AboutModel {
        AboutModel(
            appName: "Sorello", version: "0.0.1", build: "1", copyright: "Copyright 2026 Audeo Labs",
            modelNotice: NoticeItem(id: "model", title: "kea-b-0.1",
                                    detail: "Derived from NVIDIA Parakeet v2, CC-BY-4.0. Licence and attribution."),
            thirdPartyNotices: [
                NoticeItem(id: "geist", title: "Geist Serif", detail: "Vercel, SIL Open Font License 1.1."),
                NoticeItem(id: "permission-card", title: "Permission card",
                           detail: "Adapted from Scrawl and AskForPermission, MIT License."),
            ])
    }
}

/// A sample main window at `section`.
public extension MainWindowModel {
    static func sample(section: MainSection = .general, status: AppStatus = .sampleReady) -> MainWindowModel {
        MainWindowModel(section: section, general: .sample(status: status), shortcuts: .sample(),
                        dictionary: .sample(), macros: .sample(), runLog: .sample(), about: .sample())
    }
}

/// A sample setup at `step`.
public extension SetupModel {
    static func sample(step: SetupStep, microphone: MicrophoneStatus = .notDetermined,
                       accessibility: AccessibilityStatus = .missing, model: ModelStatus = .ready,
                       testText: String = "") -> SetupModel {
        SetupModel(appName: "Sorello", step: step, microphone: microphone, accessibility: accessibility, model: model,
                   holdToTalk: ShortcutRecorderState(keys: .function), testText: testText)
    }
}

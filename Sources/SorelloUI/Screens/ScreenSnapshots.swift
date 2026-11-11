import DesignCore
import SwiftUI

/// The windows' scenes for the snapshot tool: every section of the main window with invented data and its empty and
/// error states, and each setup step. The menu is the system's to draw; `StatusMenuSnapshots` lists its states as text. Main window sections are drawn tall enough to
/// show all their content, and again at the window's minimum size, where nothing may be clipped. Clock-driven
/// animations are held at `frozenPhase`, so every render of a scene is the same picture.
public enum ScreenSnapshots {
    /// Where the scenes hold the preparing dot and the glacier line: the line's segment in the middle of its travel.
    public static let frozenPhase = 0.4

    /// Every window scene, in the order the tool writes them.
    public static var scenes: [SnapshotScene] {
        mainWindow + setup
    }

    // MARK: Main window

    private static var mainWindow: [SnapshotScene] {
        let problems = AppStatus(model: .failed(.couldNotLoad), microphone: .denied, accessibility: .missing)
        let preparing = AppStatus(model: .preparing, microphone: .notDetermined, accessibility: .granted)
        var scenes: [SnapshotScene] = [
            main("general", height: 1060, .sample(section: .general)),
            // A build that can update itself: General has the switch for the daily check.
            main("general-updates", height: 1120, window(.general) { window in
                window.general.offersUpdates = true
                window.general.toggles[.checkForUpdates] = true
                return window
            }),
            main("general-problems", height: 1100, .sample(section: .general, status: problems)),
            main("general-preparing", height: 640, .sample(section: .general, status: preparing)),
            main("general-cpu", height: 640, window(.general) { $0.generalReplaced(.sample(hardware: .processor)) }),
            main("general-cpu-preparing", height: 640,
                 window(.general) { $0.generalReplaced(.sample(status: preparing, hardware: .processor)) }),
            main("general-not-downloaded", height: 640, .sample(section: .general, status: model(.sampleNotDownloaded))),
            main("general-downloading", height: 640, .sample(section: .general, status: model(.sampleDownloading))),
            main("general-download-failed", height: 640,
                 .sample(section: .general, status: model(.sampleDownloadFailed))),
            main("general-download-full-disk", height: 640, .sample(section: .general, status: model(
                .notDownloaded(.failed(.disk, size: sampleModelSize))))),
            main("general-no-build", height: 640, .sample(section: .general, status: model(.sampleNoBuild))),
            main("shortcuts", height: 720, .sample(section: .shortcuts)),
            main("shortcuts-recording", height: 760, window(.shortcuts) { $0.shortcutsReplaced(.sample(recording: true)) }),
            main("shortcuts-prompt", height: 720, window(.shortcuts) { $0.shortcutsReplaced(.sample(doubleTap: .prompt)) }),
            main("shortcuts-off", height: 720, window(.shortcuts) { $0.shortcutsReplaced(.sample(doubleTap: .off)) }),
            main("dictionary", height: 940, .sample(section: .dictionary)),
            main("dictionary-refusing", height: 960, window(.dictionary) { $0.dictionaryReplaced(.sampleRefusing()) }),
            main("dictionary-needs-model", height: 960, window(.dictionary) { $0.dictionaryReplaced(.sampleNeedsModel()) }),
            main("dictionary-empty", height: 700, window(.dictionary) { $0.dictionaryReplaced(.sampleEmpty()) }),
            main("macros", height: 640, .sample(section: .macros)),
            main("macros-editing", height: 700, window(.macros) { $0.macrosReplaced(.sample(editing: true)) }),
            main("macros-empty", height: 640, window(.macros) { $0.macrosReplaced(MacrosModel(macros: [])) }),
            main("runlog", height: 760, .sample(section: .runLog)),
            main("runlog-empty", height: 640, window(.runLog) { $0.runLogReplaced(RunLogModel(items: [])) }),
            main("runlog-off", height: 640, window(.runLog) { $0.runLogReplaced(RunLogModel(items: [], isEnabled: false)) }),
            main("about", height: 860, .sample(section: .about)),
        ]
        let minimum = WindowChrome.Kind.main.minimumSize
        for section in MainSection.allCases {
            scenes.append(SnapshotScene(name: "main-minimum-\(section.slug)", size: minimum) {
                MainWindowView(model: .sample(section: section, status: problems))
                    .environment(\.frozenAnimationPhase, frozenPhase)
            })
        }
        return scenes
    }

    private static func main(_ name: String, height: CGFloat, _ model: @autoclosure @escaping () -> MainWindowModel)
        -> SnapshotScene {
        SnapshotScene(name: "main-\(name)",
                      size: CGSize(width: WindowChrome.Kind.main.defaultSize.width, height: height)) {
            MainWindowView(model: model())
                .environment(\.frozenAnimationPhase, frozenPhase)
        }
    }

    private static func window(_ section: MainSection, _ change: (MainWindowModel) -> MainWindowModel) -> MainWindowModel {
        change(.sample(section: section))
    }

    /// Everything granted, with the model as given.
    private static func model(_ model: ModelStatus) -> AppStatus {
        AppStatus(model: model, microphone: .granted, accessibility: .granted)
    }

    // MARK: Setup

    private static var setup: [SnapshotScene] {
        let preparing = ModelStatus.preparing
        let scenes: [(String, SetupModel)] = [
            ("welcome", .sample(step: .welcome)),
            ("microphone", .sample(step: .microphone)),
            ("microphone-denied", .sample(step: .microphone, microphone: .denied)),
            ("microphone-granted", .sample(step: .microphone, microphone: .granted)),
            ("accessibility", .sample(step: .accessibility, microphone: .granted)),
            ("accessibility-granted", .sample(step: .accessibility, microphone: .granted, accessibility: .granted)),
            ("shortcut", .sample(step: .shortcut, microphone: .granted, accessibility: .granted)),
            ("shortcut-longest", longestShortcut()),
            ("test", .sample(step: .test, microphone: .granted, accessibility: .granted)),
            ("test-preparing", .sample(step: .test, microphone: .granted, accessibility: .granted, model: preparing)),
            ("test-done", .sample(step: .test, microphone: .granted, accessibility: .granted,
                                  testText: "Sphinx of black quartz, judge my vow.")),
            ("test-failed", .sample(step: .test, microphone: .granted, accessibility: .granted,
                                    model: .failed(.couldNotLoad))),
            ("test-full", .sample(step: .test, microphone: .granted, accessibility: .granted,
                                  testText: fullTestField)),
            ("model", .sample(step: .model, model: .sampleNotDownloaded, includesModel: true)),
            ("model-downloading", .sample(step: .model, model: .sampleDownloading, includesModel: true)),
            ("model-failed", .sample(step: .model, model: .sampleDownloadFailed, includesModel: true)),
            ("model-done", .sample(step: .model, model: .preparing, includesModel: true)),
            ("model-no-build", .sample(step: .model, model: .sampleNoBuild, includesModel: true)),
            ("test-downloading", .sample(step: .test, microphone: .granted, accessibility: .granted,
                                         model: .sampleDownloading, includesModel: true)),
            ("test-not-downloaded", .sample(step: .test, microphone: .granted, accessibility: .granted,
                                            model: .sampleNotDownloaded, includesModel: true)),
        ]
        return scenes.map { name, model in
            SnapshotScene(name: "setup-\(name)", size: WindowChrome.Kind.setup.defaultSize) {
                SetupView(model: model)
                    .environment(\.frozenAnimationPhase, frozenPhase)
            }
        }
    }
}

/// More dictation than setup's test field shows at once, so it scrolls.
private let fullTestField = Array(repeating: "Pack my box with five dozen liquor jugs, then carry it up the hill.",
                                  count: 8).joined(separator: " ")

/// Setup's shortcut step holding the longest shortcut there can be: fn and both sides of every modifier.
private func longestShortcut() -> SetupModel {
    let model = SetupModel.sample(step: .shortcut, microphone: .granted, accessibility: .granted)
    model.holdToTalk = ShortcutRecorderState(keys: KeyCombo(modifiers: [
        .function, .control(.left), .control(.right), .option(.left), .option(.right), .shift(.left), .shift(.right),
        .command(.left), .command(.right),
    ]))
    return model
}

private extension MainSection {
    var slug: String {
        switch self {
        case .general: "general"
        case .shortcuts: "shortcuts"
        case .dictionary: "dictionary"
        case .macros: "macros"
        case .runLog: "runlog"
        case .about: "about"
        }
    }
}

private extension MainWindowModel {
    func generalReplaced(_ general: GeneralModel) -> MainWindowModel {
        MainWindowModel(section: section, general: general, shortcuts: shortcuts, dictionary: dictionary,
                        macros: macros, runLog: runLog, about: about)
    }

    func shortcutsReplaced(_ shortcuts: ShortcutsModel) -> MainWindowModel {
        MainWindowModel(section: section, general: general, shortcuts: shortcuts, dictionary: dictionary,
                        macros: macros, runLog: runLog, about: about)
    }

    func dictionaryReplaced(_ dictionary: DictionaryModel) -> MainWindowModel {
        MainWindowModel(section: section, general: general, shortcuts: shortcuts, dictionary: dictionary,
                        macros: macros, runLog: runLog, about: about)
    }

    func macrosReplaced(_ macros: MacrosModel) -> MainWindowModel {
        MainWindowModel(section: section, general: general, shortcuts: shortcuts, dictionary: dictionary,
                        macros: macros, runLog: runLog, about: about)
    }

    func runLogReplaced(_ runLog: RunLogModel) -> MainWindowModel {
        MainWindowModel(section: section, general: general, shortcuts: shortcuts, dictionary: dictionary,
                        macros: macros, runLog: runLog, about: about)
    }
}

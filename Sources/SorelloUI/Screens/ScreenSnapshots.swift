import DesignCore
import SwiftUI

/// The windows' scenes for the snapshot tool: the menu panel in each state, every section of the main window with
/// invented data and its empty and error states, and each setup step. Main window sections are drawn tall enough to
/// show all their content, and again at the window's minimum size, where nothing may be clipped. Clock-driven
/// animations are held at `frozenPhase`, so every render of a scene is the same picture.
public enum ScreenSnapshots {
    /// Where the scenes hold the preparing dot and the glacier line: the line's segment in the middle of its travel.
    public static let frozenPhase = 0.4

    /// Every window scene, in the order the tool writes them.
    public static var scenes: [SnapshotScene] {
        menuPanel + mainWindow + setup
    }

    // MARK: Menu panel

    private static var menuPanel: [SnapshotScene] {
        let states: [(String, AppStatus, String?)] = [
            ("ready", .sampleReady, MenuPanelModel.sample().lastDictation),
            ("preparing", AppStatus(model: .preparing, microphone: .granted, accessibility: .granted), nil),
            ("microphone-needed", AppStatus(model: .ready, microphone: .denied, accessibility: .granted), nil),
            ("accessibility-needed", AppStatus(model: .ready, microphone: .granted, accessibility: .missing),
             "Pack my box with five dozen liquor jugs."),
            ("model-failed", AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted),
             nil),
            ("paused", AppStatus(model: .ready, microphone: .granted, accessibility: .granted, shortcutsPaused: true),
             "How vexingly quick daft zebras jump."),
        ]
        return states.map { name, status, last in
            SnapshotScene(name: "menu-panel-\(name)", size: CGSize(width: WindowChrome.menuPanelWidth, height: 400)) {
                MenuPanelView(model: .sample(status: status, lastDictation: last))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .environment(\.frozenAnimationPhase, frozenPhase)
            }
        }
    }

    // MARK: Main window

    private static var mainWindow: [SnapshotScene] {
        let problems = AppStatus(model: .failed(.couldNotLoad), microphone: .denied, accessibility: .missing)
        let preparing = AppStatus(model: .preparing, microphone: .notDetermined, accessibility: .granted)
        var scenes: [SnapshotScene] = [
            main("general", height: 1060, .sample(section: .general)),
            main("general-problems", height: 1100, .sample(section: .general, status: problems)),
            main("general-preparing", height: 640, .sample(section: .general, status: preparing)),
            main("shortcuts", height: 720, .sample(section: .shortcuts)),
            main("shortcuts-recording", height: 760, window(.shortcuts) { $0.shortcutsReplaced(.sample(recording: true)) }),
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
        ]
        return scenes.map { name, model in
            SnapshotScene(name: "setup-\(name)", size: WindowChrome.Kind.setup.defaultSize) {
                SetupView(model: model)
                    .environment(\.frozenAnimationPhase, frozenPhase)
            }
        }
    }
}

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

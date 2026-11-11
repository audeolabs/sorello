import DictationCore
import Foundation
import MacPlatform
import Persistence
import SorelloUI

/// Every window's model, connected to the stores and the session (ARCHITECTURE.md, section 8, "Windows"). SorelloUI
/// draws plain values and reports actions through closures; this fills the values from the app's state, keeps them
/// current as it changes, and gives each closure its meaning. One instance for the app's life, made by the shell.
@MainActor
final class WindowModels {
    let menu: StatusMenuModel
    let main: MainWindowModel
    let setup: SetupModel

    let app: AppComposition
    let player = RunLogPlayer()
    private var following: [Following] = []
    /// Counts shortcut recordings, so a recording that ends late cannot end the one after it.
    var recordingNumber: UInt64 = 0
    /// The shortcut recording in progress, if any.
    var recording: Task<Void, Never>?

    init(app: AppComposition) {
        self.app = app
        let status = AppStatus(session: app.runtime.state, download: app.download?.current,
                               modelSize: app.download?.size ?? 0, accessibilityTrusted: app.live.accessibilityTrusted,
                               shortcuts: app.platform.shortcuts.status)
        menu = StatusMenuModel(appName: app.info.name, status: status, shortcuts: [:], hasLastDictation: false)
        main = MainWindowModel(
            general: GeneralModel(modelName: "", status: status, microphones: [], selectedMicrophoneID: nil,
                                  defaultMicrophoneName: nil, toggles: [:]),
            shortcuts: ShortcutsModel(recorders: [:], doubleTap: .handsFree, promptTag: ""),
            dictionary: DictionaryModel(words: [], ignored: [], knownApps: []),
            macros: MacrosModel(macros: []),
            runLog: RunLogModel(items: []),
            about: AboutModel(appName: app.info.name, version: app.info.version, build: app.info.build,
                              copyright: app.info.copyright, modelNotice: Self.modelNotice(app.info),
                              thirdPartyNotices: Self.thirdPartyNotices))
        setup = SetupModel(appName: app.info.name, microphone: status.microphone, accessibility: status.accessibility,
                           model: status.model, modelSize: app.download?.size ?? 0,
                           holdToTalk: ShortcutRecorderState(keys: .function))
        connectMenu()
        connectGeneral()
        connectShortcuts()
        connectDictionary()
        connectMacros()
        connectRunLog()
        connectAbout()
        connectSetup()
        player.onStop = { [weak self] in self?.app.live.playingID = nil }
    }

    /// Stops keeping the models current, as the app quits.
    func stop() {
        for loop in following { loop.stop() }
        following = []
        player.stop()
        app.platform.shortcuts.cancelRecording()
    }

    /// Keeps `apply` current with whatever it reads.
    func follow(_ apply: @escaping @MainActor () -> Void) {
        following.append(Following(apply))
    }

    /// The status every window shows, from the session, the model's download, the Accessibility reading and the
    /// shortcuts.
    var status: AppStatus {
        AppStatus(session: app.runtime.state, download: app.live.modelDownload, modelSize: app.download?.size ?? 0,
                  accessibilityTrusted: app.live.accessibilityTrusted, shortcuts: app.platform.shortcuts.status)
    }

    /// Key caps for the current keyboard layout.
    var formatter: ShortcutFormatter { app.platform.keyboard() }

    // MARK: - Menu

    private func connectMenu() {
        let menu = self.menu, app = self.app
        follow { [unowned self] in
            menu.status = status
            menu.shortcuts = KeyCombo.all(app.settings.shortcutBindings, formatter: formatter)
            menu.hasLastDictation = app.runtime.state.lastText != nil
            menu.updates = Updates.row(app.updater)
        }
        menu.actions = StatusMenuActions(
            copyLastDictation: { if let text = app.runtime.state.lastText { app.platform.system.copy(text) } },
            retryModel: { app.runtime.retryPreparation() },
            openGeneral: { app.navigation.openMain(.general) },
            openShortcuts: { app.navigation.openMain(.shortcuts) },
            openDictionary: { app.navigation.openMain(.dictionary) },
            openRunLog: { app.navigation.openMain(.runLog) },
            openSettings: { app.navigation.openMain(nil) },
            checkForUpdates: { app.updater?.checkForUpdates() },
            quit: { app.navigation.quit() })
    }

    // MARK: - About

    private func connectAbout() {
        let app = self.app
        main.about.showNotice = { id in
            switch id {
            case "model":
                app.navigation.showNotice(app.info.modelName ?? String(localized: "Speech model"), app.info.modelNotices)
            case "urbanist":
                app.navigation.showNotice("Urbanist", app.info.fontLicence.map { [$0] } ?? [])
            case "sparkle":
                app.navigation.showNotice("Sparkle", app.info.thirdPartyNotices.map { [$0] } ?? [])
            default:
                app.navigation.showNotice(String(localized: "Permission card"),
                                          app.info.thirdPartyNotices.map { [$0] } ?? [])
            }
        }
    }

    /// The model's notice, first on About.
    static func modelNotice(_ info: AppInfo) -> NoticeItem {
        NoticeItem(id: "model", title: info.modelName ?? String(localized: "Speech model"),
                   detail: String(localized: "Derived from NVIDIA Parakeet v2, CC-BY-4.0. Licence and attribution.",
                                  comment: "About: the speech model's notice"))
    }

    /// Everyone else's work the app includes (ThirdPartyNotices.md).
    static var thirdPartyNotices: [NoticeItem] {
        [NoticeItem(id: "urbanist", title: "Urbanist",
                    detail: String(localized: "The Urbanist Project Authors, SIL Open Font License 1.1.",
                                   comment: "About: the display font's notice")),
         NoticeItem(id: "permission-card", title: String(localized: "Permission card"),
                    detail: String(localized: "Adapted from Scrawl and AskForPermission, MIT License.",
                                   comment: "About: the permission card's notice")),
         NoticeItem(id: "sparkle", title: "Sparkle",
                    detail: String(localized: "Andy Matuschak and the Sparkle Project, MIT License.",
                                   comment: "About: the updater's notice"))]
    }
}

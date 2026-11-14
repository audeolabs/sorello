import DictationCore
import MacPlatform
import Persistence
import SorelloUI

extension WindowModels {
    /// General: the model's state and where it runs, the permissions, the microphone and the switches. Launch at
    /// login shows what the system has, not what was last asked for, because the user can change it in System
    /// Settings. Where the model runs was settled when the engine was made, so it is read once.
    func connectGeneral() {
        let general = main.general, app = self.app
        general.hardware = ModelHardware(app.speech.compute)
        general.offersUpdates = app.updater != nil
        follow { [unowned self] in
            general.modelName = app.info.modelName ?? String(localized: "Speech model",
                                                             comment: "General: the model's row, when it has no name")
            general.status = status
            general.microphones = app.live.microphones.map { MicrophoneOption(id: $0.id, name: $0.name) }
            general.selectedMicrophoneID = app.settings.microphoneID
            general.defaultMicrophoneName = app.live.microphones.first(where: \.isDefault)?.name
            let choice = MicrophoneChoice.resolve(app.live.microphones, chosenID: app.settings.microphoneID,
                                                  avoidBluetooth: app.settings.avoidBluetoothMicrophone)
            general.standInMicrophoneName = choice?.replacing == nil ? nil : choice?.device.name
            var toggles = Self.toggles(app.settings, login: app.platform.loginItem.state)
            if let updater = app.updater { toggles[.checkForUpdates] = updater.checksAutomatically }
            general.toggles = toggles
        }
        general.actions = GeneralActions(
            retryModel: { app.runtime.retryPreparation() },
            downloadModel: { app.startDownload() },
            cancelDownload: { app.cancelDownload() },
            requestMicrophone: { [unowned self] in requestMicrophone(from: .main) },
            openMicrophoneSettings: { app.platform.system.openMicrophoneSettings() },
            openAccessibilitySettings: { [unowned self] in grantAccessibility() },
            selectMicrophone: { app.settings.microphoneID = $0 },
            setToggle: { [unowned self] toggle, on in setToggle(toggle, on) })
    }

    /// Each switch's value.
    static func toggles(_ settings: SettingsStore, login: LoginItem.State) -> [GeneralToggle: Bool] {
        [.launchAtLogin: login == .enabled || login == .requiresApproval,
         .restoreClipboard: settings.restoreClipboard,
         .spokenNumbers: settings.spokenNumbers,
         .spokenDelimiters: settings.spokenDelimiters,
         .pressEnter: settings.pressEnterCommand,
         .correctionSuggestions: settings.correctionSuggestions,
         .keepRunLog: settings.keepRunLog,
         .avoidBluetoothMicrophone: settings.avoidBluetoothMicrophone]
    }

    func setToggle(_ toggle: GeneralToggle, _ on: Bool) {
        let settings = app.settings
        switch toggle {
        case .launchAtLogin:
            settings.launchAtLogin = on
            let login = app.platform.loginItem
            do {
                try login.setEnabled(on)
            } catch {
                Diagnostics.record("app.loginItemNotChanged")
            }
            if on && login.state == .requiresApproval { login.openSystemSettings() }
        case .restoreClipboard: settings.restoreClipboard = on
        case .spokenNumbers: settings.spokenNumbers = on
        case .spokenDelimiters: settings.spokenDelimiters = on
        case .pressEnter: settings.pressEnterCommand = on
        case .correctionSuggestions: settings.correctionSuggestions = on
        case .keepRunLog: settings.keepRunLog = on
        case .avoidBluetoothMicrophone: settings.avoidBluetoothMicrophone = on
        case .checkForUpdates: app.updater?.checksAutomatically = on
        }
    }

    /// Allow, in setup or on the General screen: asks for the microphone (the system shows its prompt only while
    /// access was never decided) and, once it has answered, brings `window`, which asked, in front again, since the
    /// prompt leaves whatever it likes in front. A dictation asks through the session instead, and that never brings a
    /// window forward.
    func requestMicrophone(from window: AppWindow) {
        let app = self.app
        Task {
            _ = await app.platform.microphone.request()
            app.runtime.refreshMicrophoneAccess()
            app.navigation.bringBack(window)
        }
    }

    /// Opens System Settings with the card to drag in; a grant restarts the shortcuts at once.
    func grantAccessibility() {
        let app = self.app
        app.platform.system.grantAccessibility { granted in
            guard granted else { return }
            app.live.accessibilityTrusted = true
            app.platform.shortcuts.start()
        }
    }
}

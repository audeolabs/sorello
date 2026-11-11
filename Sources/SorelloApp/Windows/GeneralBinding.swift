import DictationCore
import MacPlatform
import Persistence
import SorelloUI

extension WindowModels {
    /// General: the model's state, the permissions, the microphone and the switches. Launch at login shows what the
    /// system has, not what was last asked for, because the user can change it in System Settings.
    func connectGeneral() {
        let general = main.general, app = self.app
        follow { [unowned self] in
            general.modelName = app.info.modelName ?? String(localized: "No speech model",
                                                             comment: "General: the app was built without a model")
            general.status = status
            general.microphones = app.live.microphones.map { MicrophoneOption(id: $0.id, name: $0.name) }
            general.selectedMicrophoneID = app.settings.microphoneID
            general.defaultMicrophoneName = app.live.microphones.first(where: \.isDefault)?.name
            general.toggles = Self.toggles(app.settings, login: app.platform.loginItem.state)
        }
        general.actions = GeneralActions(
            retryModel: { app.runtime.retryPreparation() },
            requestMicrophone: { [unowned self] in requestMicrophone() },
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
         .keepRunLog: settings.keepRunLog]
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
        }
    }

    /// Asks for the microphone; the system shows its prompt only while access was never decided.
    func requestMicrophone() {
        let app = self.app
        Task {
            _ = await app.platform.microphone.request()
            app.runtime.refreshMicrophoneAccess()
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

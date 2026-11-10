import DictationCore
import MacPlatform
import Persistence
import SorelloUI

extension WindowModels {
    /// Shortcuts: a recorder per action, what the double tap does, and the fn key's note. Recording reads the next keys from the
    /// monitor's own tap; what it captures is checked by `ShortcutValidation` before it is saved, and a refusal is
    /// shown under the recorder until the next attempt.
    func connectShortcuts() {
        let shortcuts = main.shortcuts, app = self.app
        follow { [unowned self] in
            shortcuts.recorders = recorders()
            shortcuts.doubleTap = DoubleTapChoice(app.settings.doubleTap)
            shortcuts.promptTag = app.settings.promptTag
        }
        shortcuts.recorderActions = recorderActions
        shortcuts.setDoubleTap = { app.settings.doubleTap = DoubleTapAction($0) }
        shortcuts.openKeyboardSettings = { if let pane = SettingsPane.keyboard { app.platform.system.open(pane) } }
    }

    /// Every action's recorder as it stands.
    func recorders() -> [ShortcutKind: ShortcutRecorderState] {
        let formatter = self.formatter
        var recorders: [ShortcutKind: ShortcutRecorderState] = [:]
        for kind in ShortcutKind.allCases {
            recorders[kind] = ShortcutRecorderState(
                keys: app.settings.shortcut(for: kind.action).map { KeyCombo($0, formatter: formatter) },
                isRecording: app.live.recording == kind, refusal: app.live.refusals[kind])
        }
        return recorders
    }

    /// Record, cancel and clear, for the Shortcuts screen and setup's shortcut step.
    var recorderActions: ShortcutRecorderActions {
        ShortcutRecorderActions(record: { [unowned self] in record($0) },
                                cancel: { [unowned self] in cancelRecording($0) },
                                clear: { [unowned self] in clear($0) })
    }

    func record(_ kind: ShortcutKind) {
        let live = app.live, settings = app.settings, monitor = app.platform.shortcuts
        // Starting a recording ends the one before it without a binding.
        if live.recording != nil { monitor.cancelRecording() }
        recordingNumber += 1
        let number = recordingNumber
        live.refusals[kind] = nil
        live.recording = kind
        recording?.cancel()
        recording = Task { [weak self] in
            // Cancelled before it began: never take the keyboard.
            guard let self, self.recordingNumber == number, !Task.isCancelled else { return }
            let binding = await monitor.recordBinding()
            guard self.recordingNumber == number else { return }
            live.recording = nil
            guard let binding else { return }
            if let problem = ShortcutValidation.problem(with: binding, for: kind.action, among: settings.shortcutBindings) {
                live.refusals[kind] = ShortcutRefusal(problem)
            } else {
                settings.setShortcut(binding, for: kind.action)
            }
        }
    }

    /// Ends `kind`'s recording, if it is the one recording. Safe to call any number of times: a recorder cancels
    /// itself when its screen disappears.
    func cancelRecording(_ kind: ShortcutKind) {
        guard app.live.recording == kind else { return }
        recordingNumber += 1
        app.live.recording = nil
        recording?.cancel()
        recording = nil
        app.platform.shortcuts.cancelRecording()
    }

    /// Leaves Tap to Toggle or Paste Again without a shortcut, or puts Hold to Talk back to fn.
    func clear(_ kind: ShortcutKind) {
        let settings = app.settings
        app.live.refusals[kind] = nil
        guard kind == .holdToTalk else {
            settings.setShortcut(nil, for: kind.action)
            return
        }
        if let problem = ShortcutValidation.problem(with: .function, for: .holdToTalk, among: settings.shortcutBindings) {
            app.live.refusals[kind] = ShortcutRefusal(problem)
        } else {
            settings.setShortcut(.function, for: .holdToTalk)
        }
    }
}

extension WindowModels {
    /// Setup: the permissions and the model as every window shows them, Hold to Talk's recorder, and the live test,
    /// whose field the view owns. Done marks setup finished and closes it.
    func connectSetup() {
        let setup = self.setup, app = self.app
        follow { [unowned self] in
            let status = self.status
            setup.microphone = status.microphone
            setup.accessibility = status.accessibility
            setup.model = status.model
            setup.holdToTalk = recorders()[.holdToTalk] ?? ShortcutRecorderState(keys: nil)
        }
        setup.actions = SetupActions(
            requestMicrophone: { [unowned self] in requestMicrophone() },
            openMicrophoneSettings: { app.platform.system.openMicrophoneSettings() },
            openAccessibilitySettings: { [unowned self] in grantAccessibility() },
            openKeyboardSettings: { if let pane = SettingsPane.keyboard { app.platform.system.open(pane) } },
            retryModel: { app.runtime.retryPreparation() },
            recorder: recorderActions,
            finish: {
                app.settings.setupCompleted = true
                app.navigation.closeSetup()
            })
    }

    /// Whether setup should open at launch: the first time, and whenever a permission is missing. The microphone is
    /// missing only once it was refused; never asked is not a problem, because the first dictation asks.
    var setupIsNeeded: Bool {
        let status = self.status
        return !app.settings.setupCompleted || status.accessibility == .missing || status.microphone == .denied
    }

    /// The step setup opens at: the start the first time, otherwise the first permission that is missing.
    var setupStartStep: SetupStep {
        let status = self.status
        guard app.settings.setupCompleted else { return .welcome }
        if status.microphone == .denied { return .microphone }
        if status.accessibility == .missing { return .accessibility }
        return .welcome
    }
}

extension DoubleTapChoice {
    /// The Shortcuts screen's name for the session's double-tap setting.
    init(_ action: DoubleTapAction) {
        switch action {
        case .handsFree: self = .handsFree
        case .prompt: self = .prompt
        case .off: self = .off
        }
    }
}

extension DoubleTapAction {
    /// The session's setting for what the Shortcuts screen offers.
    init(_ choice: DoubleTapChoice) {
        switch choice {
        case .handsFree: self = .handsFree
        case .prompt: self = .prompt
        case .off: self = .off
        }
    }
}

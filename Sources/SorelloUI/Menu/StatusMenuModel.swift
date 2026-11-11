import Foundation
import Observation

/// What choosing a command in the menu-bar item's menu asks the app to do.
nonisolated public enum StatusMenuCommand: Hashable, Sendable {
    /// Load the speech model again after a failure.
    case retryModel
    /// Open the main window's General screen, where a missing permission is fixed and the model is downloaded.
    case openGeneral
    /// Open the main window at Shortcuts.
    case openShortcuts
    /// Put the last dictation on the clipboard.
    case copyLastDictation
    /// Open the main window at Dictionary.
    case openDictionary
    /// Open the main window at the Run Log.
    case openRunLog
    /// Open the main window, at the section it last showed.
    case openSettings
    /// Quit the app.
    case quit
}

/// What the menu's commands do. The app layer supplies each, so the menu never reaches into the session, the
/// clipboard or the windows itself.
public struct StatusMenuActions {
    /// Put the last dictation on the clipboard.
    public var copyLastDictation: () -> Void
    /// Load the speech model again after a failure.
    public var retryModel: () -> Void
    /// Open the main window's General screen, where a missing permission is fixed and the model is downloaded.
    public var openGeneral: () -> Void
    /// Open the main window at Shortcuts.
    public var openShortcuts: () -> Void
    /// Open the main window at Dictionary.
    public var openDictionary: () -> Void
    /// Open the main window at the Run Log.
    public var openRunLog: () -> Void
    /// Open the main window, at the section it last showed.
    public var openSettings: () -> Void
    /// Quit the app.
    public var quit: () -> Void

    /// Actions that each do nothing unless given.
    public init(copyLastDictation: @escaping () -> Void = {}, retryModel: @escaping () -> Void = {},
                openGeneral: @escaping () -> Void = {}, openShortcuts: @escaping () -> Void = {},
                openDictionary: @escaping () -> Void = {}, openRunLog: @escaping () -> Void = {},
                openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) {
        self.copyLastDictation = copyLastDictation
        self.retryModel = retryModel
        self.openGeneral = openGeneral
        self.openShortcuts = openShortcuts
        self.openDictionary = openDictionary
        self.openRunLog = openRunLog
        self.openSettings = openSettings
        self.quit = quit
    }

    /// Runs the action `command` asks for.
    public func perform(_ command: StatusMenuCommand) {
        switch command {
        case .retryModel: retryModel()
        case .openGeneral: openGeneral()
        case .openShortcuts: openShortcuts()
        case .copyLastDictation: copyLastDictation()
        case .openDictionary: openDictionary()
        case .openRunLog: openRunLog()
        case .openSettings: openSettings()
        case .quit: quit()
        }
    }
}

/// The values the menu-bar item's menu is made from. The app layer keeps them current; the menu reads them each time
/// it opens and follows them while it is open.
@Observable
public final class StatusMenuModel {
    /// The app's name as installed, from the bundle, for Quit.
    public var appName: String
    /// The model and permissions, for the state line.
    public var status: AppStatus
    /// The shortcuts. An action without one shows "Not set".
    public var shortcuts: [ShortcutKind: KeyCombo]
    /// Whether there is a last dictation, so Copy Last Dictation can be used. The menu is never told what it says:
    /// choosing Copy asks the app layer, which copies it from the session.
    public var hasLastDictation: Bool
    /// What the menu's commands ask of the app layer.
    public var actions: StatusMenuActions

    /// The menu's values.
    public init(appName: String, status: AppStatus, shortcuts: [ShortcutKind: KeyCombo], hasLastDictation: Bool,
                actions: StatusMenuActions = StatusMenuActions()) {
        self.appName = appName
        self.status = status
        self.shortcuts = shortcuts
        self.hasLastDictation = hasLastDictation
        self.actions = actions
    }

    /// The menu's rows, from the top, for the values as they are now.
    public var rows: [StatusMenuRow] {
        StatusMenuRow.rows(appName: appName, status: status, shortcuts: shortcuts, hasLastDictation: hasLastDictation)
    }
}

import AppKit
import DictationCore
import DictionaryKit
import MacPlatform
import Observation

// The macOS adapters the app is built from, behind the few protocols the composition needs, so the whole graph can
// be built in a test with fakes: nothing in a test posts a key, reads the pasteboard, opens a panel or asks for a
// permission. `AppPlatform.system()` gives the real adapters; nothing else in the app constructs them.

/// The insertion adapter, and the wait the app does before it quits so a clipboard waiting to be put back is not lost.
protocol AppInserting: TextInserting {
    func waitUntilIdle() async
}

extension PasteboardInserter: AppInserting {}

/// The global shortcuts, as `ShortcutMonitor` offers them.
@MainActor
protocol ShortcutService: AnyObject {
    var status: ShortcutMonitor.Status { get }
    var handler: (any TriggerHandling)? { get set }
    func start()
    func stop()
    func setBindings(_ bindings: [ShortcutAction: ShortcutBinding])
    func recordBinding() async -> ShortcutBinding?
    func cancelRecording()
}

extension ShortcutMonitor: ShortcutService {}

/// Launch at login, as `LoginItem` offers it.
@MainActor
protocol LoginItemControlling: AnyObject {
    var state: LoginItem.State { get }
    func refresh()
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

extension LoginItem: LoginItemControlling {}

/// Whether Sorello is trusted for Accessibility, and each change. Reading it never prompts.
protocol AccessibilityTrust: Sendable {
    var isTrusted: Bool { get }
    func changes() -> AsyncStream<Bool>
}

extension AccessibilityPermission: AccessibilityTrust {}

/// The microphones connected now, and each change, for the General screen's picker.
protocol MicrophoneListing: Sendable {
    func current() -> [AudioInputDevice]
    func changes() -> AsyncStream<[AudioInputDevice]>
}

extension AudioInputDevices: MicrophoneListing {}

/// What the windows' buttons do outside the app: System Settings panes, the clipboard, choosing an app, playing a
/// recording. Closures, so a test records what was asked instead of doing it.
struct SystemActions {
    /// Opens a System Settings pane.
    var open: @MainActor (URL) -> Void
    /// Puts text on the general pasteboard, for a Copy button the user pressed.
    var copy: @MainActor (String) -> Void
    /// Lets the user choose an app in Applications; nil when they cancel.
    var chooseApp: @MainActor () async -> AppIdentity?
    /// Shows the Accessibility drag card over System Settings; `finished` is told whether access was granted.
    var grantAccessibility: @MainActor (_ finished: @escaping @MainActor (Bool) -> Void) -> Void
    /// Opens the microphone pane of System Settings.
    var openMicrophoneSettings: @MainActor () -> Void
}

/// Every macOS adapter the app uses.
@MainActor
struct AppPlatform {
    var capture: any AudioCapturing
    var microphone: any MicrophoneAuthorizing
    var frontmostApp: any FrontmostAppReading
    var inserter: any AppInserting
    /// One reader serves the inserter and the correction watch.
    var fieldReader: any TextFieldReading
    var accessibility: any AccessibilityTrust
    var shortcuts: any ShortcutService
    var loginItem: any LoginItemControlling
    var microphones: any MicrophoneListing
    var keyboard: @MainActor () -> ShortcutFormatter
    var clock: any SessionClock
    var system: SystemActions

    /// The real adapters. Building them prompts for nothing and starts nothing: the event tap is created by
    /// `ShortcutService.start()`, the microphone by a dictation.
    static func system(bindings: [ShortcutAction: ShortcutBinding]) -> AppPlatform {
        let clock = SystemSessionClock()
        let reader = AccessibilityTextFieldReader()
        let microphone = MicrophonePermission()
        let grant = AccessibilityGrant()
        return AppPlatform(
            capture: MicrophoneCapture(clock: clock), microphone: microphone, frontmostApp: FrontmostApp(),
            inserter: PasteboardInserter.system(reader: reader), fieldReader: reader,
            accessibility: AccessibilityPermission(clock: clock),
            shortcuts: ShortcutMonitor(bindings: bindings, clock: clock), loginItem: LoginItem(),
            microphones: AudioInputDevices(),
            keyboard: { ShortcutFormatter(layout: KeyboardLayoutSnapshot.current()) }, clock: clock,
            system: SystemActions(
                open: { NSWorkspace.shared.open($0) },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                chooseApp: { await AppChooser.choose() },
                grantAccessibility: { finished in grant.start(finished: finished) },
                openMicrophoneSettings: { microphone.openSettings() }))
    }
}

/// System Settings panes Sorello points at. It never changes a system setting itself.
enum SettingsPane {
    /// Keyboard, where the fn key's own action is chosen.
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
}

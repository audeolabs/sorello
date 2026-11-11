import AppKit
import DesignCore
import DictationCore
import MacPlatform
import UniformTypeIdentifiers

// The two system panels the windows open: choosing an app to limit a word to, and the Accessibility drag card.

/// Lets the user choose an app in Applications, for a dictionary word limited to it.
@MainActor
enum AppChooser {
    /// The chosen app's bundle identifier and name, or nil when the user cancels or the bundle has no identifier.
    static func choose() async -> AppIdentity? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an App", comment: "Title of the panel that picks an app for a word")
        panel.prompt = String(localized: "Choose", comment: "Button that picks the selected app")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate()
        guard await panel.begin() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppIdentity(bundleID: identifier, name: name)
    }
}

/// The Accessibility drag card over System Settings. A second request replaces the card that is up.
@MainActor
final class AccessibilityGrant {
    private var current: PermissionPanel.Controller?

    /// Opens the Accessibility pane with the card; `finished` hears whether access was granted.
    func start(finished: @escaping @MainActor (Bool) -> Void) {
        current?.cancel()
        let controller = PermissionPanel.Controller(source: nil, style: .sorello)
        controller.onFinish = { [weak self, weak controller] granted in
            if let self, self.current === controller { self.current = nil }
            finished(granted)
        }
        current = controller
        controller.start()
    }
}

extension PermissionCardStyle {
    /// The card in Sorello's colours (ARCHITECTURE.md, section 8): white ink, the screen behind the glass, the card
    /// colour for the app row with its hairline, and aurora for the check mark.
    static var sorello: PermissionCardStyle {
        func colour(_ rgb: RGB) -> Colour { Colour(red: rgb.red, green: rgb.green, blue: rgb.blue) }
        return PermissionCardStyle(ink: colour(Palette.ink), secondaryInkAlpha: Palette.secondaryInkAlpha,
                                   surface: colour(Palette.screen), row: colour(Palette.card),
                                   edge: colour(Palette.edge), done: colour(Palette.aurora))
    }
}

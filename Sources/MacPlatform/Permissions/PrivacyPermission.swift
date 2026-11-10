import Foundation

/// The two privacy permissions Sorello needs, with the words and System Settings links that go with them. Pane
/// names change across macOS versions (Accessibility is "Device Control and Data Access" on macOS 27, and
/// "Accessibility" from macOS 15 to 26), while the Settings URL anchors stay the same.
public enum PrivacyPermission: CaseIterable, Sendable {
    case microphone, accessibility

    /// The pane's title in System Settings > Privacy & Security on that macOS version.
    public func settingsTitle(macOSMajorVersion: Int) -> String {
        switch self {
        case .microphone:
            String(localized: "Microphone")
        case .accessibility:
            macOSMajorVersion >= 27 ? String(localized: "Device Control and Data Access")
                : String(localized: "Accessibility")
        }
    }

    /// The pane's title on this Mac.
    public var settingsTitle: String {
        settingsTitle(macOSMajorVersion: Self.currentMajorVersion)
    }

    public func enableInstructions(appName: String, macOSMajorVersion: Int) -> String {
        let pane = settingsTitle(macOSMajorVersion: macOSMajorVersion)
        return String(localized: "Go to System Settings > Privacy & Security > \(pane) and enable \(appName).")
    }

    public func enableInstructions(appName: String) -> String {
        enableInstructions(appName: appName, macOSMajorVersion: Self.currentMajorVersion)
    }

    /// For Accessibility: what to do when the app is listed as enabled but access is still missing, which happens
    /// after the app is replaced by a new build.
    public static var accessibilityRepairInstructions: String {
        String(localized: """
            If the app is already enabled but access is still missing, remove its entry with −, add this copy \
            with +, and enable it again.
            """)
    }

    /// The permission's pane in System Settings.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        // Both strings are fixed here, so the URL always parses.
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Privacy & Security, for when the pane itself cannot be opened.
    public static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// Whether the permission's Settings list takes an app dragged into it. Microphone access is granted through
    /// the system's prompt instead.
    public var acceptsDraggedApp: Bool {
        switch self {
        case .microphone: false
        case .accessibility: true
        }
    }

    /// The alert shown when dictation needs this permission and it is missing.
    public func alertText(appName: String, macOSMajorVersion: Int) -> PermissionAlertText {
        let instructions = enableInstructions(appName: appName, macOSMajorVersion: macOSMajorVersion)
        let pane = settingsTitle(macOSMajorVersion: macOSMajorVersion)
        let title = String(localized: "\(pane) Permission Required")
        switch self {
        case .microphone:
            let message = String(localized: "\(appName) cannot record audio without Microphone access.")
            return PermissionAlertText(title: title, message: "\(message)\n\n\(instructions)", symbolName: "mic.fill")
        case .accessibility:
            let message = String(localized: "\(appName) needs this access for global shortcuts and pasting transcribed text.")
            return PermissionAlertText(
                title: title, message: "\(message)\n\n\(instructions)\n\n\(Self.accessibilityRepairInstructions)",
                symbolName: "exclamationmark.triangle.fill")
        }
    }

    public func alertText(appName: String) -> PermissionAlertText {
        alertText(appName: appName, macOSMajorVersion: Self.currentMajorVersion)
    }

    private static var currentMajorVersion: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
}

/// The words of a missing-permission alert.
public struct PermissionAlertText: Equatable, Sendable {
    public let title: String
    public let message: String
    /// An SF Symbol for the alert's icon.
    public let symbolName: String

    public init(title: String, message: String, symbolName: String) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
    }
}

extension Bundle {
    /// The app's name as the user sees it, read from the bundle: its display name, else its name, else the
    /// process name.
    var appDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }
}

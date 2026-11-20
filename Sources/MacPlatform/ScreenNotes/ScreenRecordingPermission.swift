import AppKit
import CoreGraphics

/// Screen Recording, which screen notes need (ARCHITECTURE.md, section 14, "Turning them on"). Reading it never asks;
/// only `request`, which the app calls when the user turns screen notes on, shows the system's prompt.
public struct ScreenRecordingPermission: Sendable {
    public init() {}

    /// Whether this process may record the screen now.
    public var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks the system for access: its prompt the first time, System Settings after that. Returns whether access is
    /// granted now; a grant made in System Settings may take effect only once the app is opened again.
    @discardableResult
    public func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Opens the Screen Recording pane of System Settings.
    @MainActor
    public func openSettings() {
        guard let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(pane)
    }
}

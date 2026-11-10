import AppKit
@preconcurrency import AVFoundation
import DictationCore

/// Microphone access (the `MicrophoneAuthorizing` port). Reading it never prompts; `request` shows the system's
/// prompt only while access has never been decided, which the session asks for the first time a dictation needs
/// the microphone.
public struct MicrophonePermission: MicrophoneAuthorizing {
    private let status: @Sendable () -> AVAuthorizationStatus
    private let ask: @Sendable () async -> Bool

    public init() {
        self.init(status: { AVCaptureDevice.authorizationStatus(for: .audio) },
                  ask: { await AVCaptureDevice.requestAccess(for: .audio) })
    }

    init(status: @escaping @Sendable () -> AVAuthorizationStatus, ask: @escaping @Sendable () async -> Bool) {
        self.status = status
        self.ask = ask
    }

    public func current() -> MicrophoneAccess {
        switch status() {
        case .authorized: .granted
        case .notDetermined: .unknown
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func request() async -> MicrophoneAccess {
        guard current() == .unknown else { return current() }
        return await ask() ? .granted : .denied
    }

    /// Opens the Microphone pane of System Settings, where a denied access can be changed.
    @MainActor
    public func openSettings() {
        PrivacyPermission.microphone.openSettings()
    }
}

extension PrivacyPermission {
    /// Opens the permission's pane in System Settings, or Privacy & Security when that fails.
    @MainActor
    func openSettings() {
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(Self.privacySettingsURL)
        }
    }
}

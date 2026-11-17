import AppIntents

/// The host side of the voice note's intents: `HostSessionController`, in the app only.
@MainActor
protocol VoiceNoteIntentHandling: AnyObject {
    func toggleNoteFromControl() async -> VoiceNoteIntentStep
    func startNoteFromActivity() -> VoiceNoteIntentStep
    func stopNoteFromActivity() -> VoiceNoteIntentStep
}

/// Where the voice note's intents find the host (ARCHITECTURE.md, "Voice Note control").
@MainActor
enum VoiceNoteIntentHost {
    /// Set by the app as it launches; never in the extension, where every `perform` throws.
    static var handler: VoiceNoteIntentHandling?

    static func result(_ step: VoiceNoteIntentStep) throws -> some IntentResult {
        if let message = step.message { throw VoiceNoteIntentRefused(message: message) }
        return .result()
    }
}

/// The "Voice Note" control's action (ARCHITECTURE.md, "Voice Note control"): starts a voice note in a new note,
/// starting a session if none runs, or stops the note recording, without opening the app. An `AudioRecordingIntent`
/// may start the microphone in the background, and as a `LiveActivityIntent` iOS runs it in the app's process, where it
/// may start the session's Live Activity. Compiled into the app, which performs it, and the widget extension, whose
/// control names it. Kept: iOS binds a placed control to this type's name (ARCHITECTURE.md, "Identifiers").
struct ToggleVoiceNoteIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Voice Note"
    /// On a locked iPhone, iOS asks for Face ID or the passcode on this iPhone first: the control never starts a note
    /// while locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    /// Background only: with a foreground mode iOS treats the control as a launcher that opens the app.
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = VoiceNoteIntentHost.handler else { throw VoiceNoteIntentRefused.unavailable }
        return try VoiceNoteIntentHost.result(await handler.toggleNoteFromControl())
    }
}

/// The Live Activity's Note (ARCHITECTURE.md, "Live Activity", Buttons): starts a voice note in a new note in the
/// session that runs. Kept: a running activity's button names this type (ARCHITECTURE.md, "Identifiers").
struct StartVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Voice Note"
    /// Starting a recording from the Lock Screen needs the user: iOS asks for Face ID or the passcode first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = VoiceNoteIntentHost.handler else { throw VoiceNoteIntentRefused.unavailable }
        return try VoiceNoteIntentHost.result(handler.startNoteFromActivity())
    }
}

/// The Live Activity's Stop (ARCHITECTURE.md, "Live Activity", Buttons): stops the voice note in progress. Stopping
/// never needs authentication. Kept: a running activity's button names this type (ARCHITECTURE.md, "Identifiers").
struct StopVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Voice Note"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = VoiceNoteIntentHost.handler else { throw VoiceNoteIntentRefused.unavailable }
        return try VoiceNoteIntentHost.result(handler.stopNoteFromActivity())
    }
}

/// The start needs the app, or failed: the one sentence that says why (`VoiceNoteIntentStep.message`).
struct VoiceNoteIntentRefused: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    static var unavailable: VoiceNoteIntentRefused {
        VoiceNoteIntentRefused(message: VoiceNoteIntentStep.unavailable.message ?? "")
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

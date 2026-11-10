import Foundation

// What the windows say about the app's health: the speech model, the two permissions and whether shortcuts are
// paused. The app layer maps the engine's readiness and the permission adapters to these values; the menu panel's
// state line, the main window's sidebar and the General screen all read them, so they always agree.

/// The speech model as the windows show it.
nonisolated public enum ModelStatus: Equatable, Sendable {
    /// Loading and warming up. Dictation still works: the transcript waits for the model.
    case preparing
    case ready
    case failed(ModelProblem)
}

/// Why the speech model is not available.
nonisolated public enum ModelProblem: Equatable, Sendable {
    /// This build of the app has no model.
    case missing
    /// A model file does not match its manifest.
    case damaged
    /// The model is there but could not be loaded.
    case couldNotLoad

    /// One plain sentence for the General screen, under the model's state.
    public var explanation: String {
        switch self {
        case .missing: String(localized: "This copy of the app was built without the speech model.")
        case .damaged: String(localized: "A speech model file is damaged. Reinstalling the app repairs it.")
        case .couldNotLoad: String(localized: "The speech model couldn’t be loaded. Trying again usually works.")
        }
    }
}

/// Microphone access. It is asked for the first time a dictation needs it, so `notDetermined` is not a problem.
nonisolated public enum MicrophoneStatus: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
}

/// Accessibility access, granted in System Settings. Without it no shortcut works and nothing can be pasted.
nonisolated public enum AccessibilityStatus: Equatable, Sendable {
    case granted
    case missing
}

/// Everything the state line is drawn from.
nonisolated public struct AppStatus: Equatable, Sendable {
    /// The speech model.
    public var model: ModelStatus
    /// Microphone access.
    public var microphone: MicrophoneStatus
    /// Accessibility access.
    public var accessibility: AccessibilityStatus
    /// Secure input is on (a password field has the keyboard), so the shortcuts are paused.
    public var shortcutsPaused: Bool

    /// A status; shortcuts are not paused unless said.
    public init(model: ModelStatus, microphone: MicrophoneStatus, accessibility: AccessibilityStatus,
                shortcutsPaused: Bool = false) {
        self.model = model
        self.microphone = microphone
        self.accessibility = accessibility
        self.shortcutsPaused = shortcutsPaused
    }

    /// The one line that sums the status up. When several things are wrong, the one that stops dictation and needs
    /// the user comes first: the model failing, then the microphone, then Accessibility. Paused shortcuts and a
    /// model that is still preparing resolve themselves, so they come after.
    public var line: StatusLine {
        if case .failed = model {
            return StatusLine(text: String(localized: "Speech model unavailable"), indicator: .problem,
                              remedy: .retryModel)
        }
        if microphone == .denied {
            return StatusLine(text: String(localized: "Microphone access needed"), indicator: .problem,
                              remedy: .openMicrophoneSettings)
        }
        if accessibility == .missing {
            return StatusLine(text: String(localized: "Accessibility access needed"), indicator: .problem,
                              remedy: .openAccessibilitySettings)
        }
        if shortcutsPaused {
            return StatusLine(text: String(localized: "Shortcuts paused for a password field"),
                              indicator: .neutral, remedy: nil)
        }
        if model == .preparing {
            return StatusLine(text: String(localized: "Preparing model"), indicator: .preparing, remedy: nil)
        }
        return StatusLine(text: String(localized: "Ready"), indicator: .ready, remedy: nil)
    }
}

/// A short state, the mark that goes with it, and what would fix it.
nonisolated public struct StatusLine: Equatable, Sendable {
    /// How a state is marked. Colour is never the only signal: a problem is a symbol, not a dot, and every state has
    /// its words beside it.
    public enum Indicator: Equatable, Sendable {
        /// An aurora dot.
        case ready
        /// A glacier dot with a soft shimmer.
        case preparing
        /// A grey dot: nothing is wrong, but nothing is live either.
        case neutral
        /// An ember warning symbol.
        case problem
    }

    /// The action that resolves a problem.
    public enum Remedy: Equatable, Sendable {
        case retryModel
        case openMicrophoneSettings
        case openAccessibilitySettings

        /// The button's title.
        public var title: String {
            switch self {
            case .retryModel: String(localized: "Retry")
            case .openMicrophoneSettings, .openAccessibilitySettings: String(localized: "Fix…")
            }
        }

        /// What the button does, for VoiceOver.
        public var hint: String {
            switch self {
            case .retryModel: String(localized: "Loads the speech model again")
            case .openMicrophoneSettings: String(localized: "Opens the microphone settings")
            case .openAccessibilitySettings: String(localized: "Opens the Accessibility settings")
            }
        }
    }

    /// A few words: "Ready", "Microphone access needed".
    public var text: String
    /// The mark before the words.
    public var indicator: Indicator
    /// What fixes it, when something is wrong and the user can fix it.
    public var remedy: Remedy?

    /// A line.
    public init(text: String, indicator: Indicator, remedy: Remedy?) {
        self.text = text
        self.indicator = indicator
        self.remedy = remedy
    }
}

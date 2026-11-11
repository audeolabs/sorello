import Foundation

// What the windows say about the app's health: the speech model, the two permissions and whether shortcuts are
// paused. The app layer maps the engine's readiness and the permission adapters to these values; the menu's state
// line, the main window's sidebar and the General screen all read them, so they always agree.

/// The speech model as the windows show it.
nonisolated public enum ModelStatus: Equatable, Sendable {
    /// Loading and warming up. Dictation still works: the transcript waits for the model.
    case preparing
    case ready
    /// The model is on this Mac but cannot be used.
    case failed(ModelProblem)
    /// The model is not on this Mac yet: it can be downloaded, it is downloading, or there is none for this Mac.
    case notDownloaded(ModelDownloadStatus)
}

/// Why the speech model, which is on this Mac, is not available.
nonisolated public enum ModelProblem: Equatable, Sendable {
    /// A model file the app carries does not match its manifest.
    case damaged
    /// The model is there but could not be loaded.
    case couldNotLoad

    /// One plain sentence for the General screen, under the model's state.
    public var explanation: String {
        switch self {
        case .damaged: String(localized: "A speech model file is damaged. Reinstalling the app repairs it.")
        case .couldNotLoad: String(localized: "The speech model couldn’t be loaded. Trying again usually works.")
        }
    }
}

/// The model's download, as the windows show it (ARCHITECTURE.md, section 8, "The model's state"). Sizes are in
/// bytes; the windows say them as whole megabytes.
nonisolated public enum ModelDownloadStatus: Equatable, Sendable {
    /// Not downloaded yet: a download of `size` bytes, from Hugging Face.
    case notStarted(size: Int64)
    /// `received` of `size` bytes are here.
    case downloading(received: Int64, size: Int64)
    /// The last download stopped, for this reason.
    case failed(ModelDownloadProblem, size: Int64)
    /// No build of the model fits this Mac, so there is nothing to download.
    case unavailable

    /// Whether the user can start a download from here.
    public var offersDownload: Bool {
        switch self {
        case .notStarted, .failed: true
        case .downloading, .unavailable: false
        }
    }
}

/// Why a download stopped, in one of four plain sentences. None names an address or a file.
nonisolated public enum ModelDownloadProblem: Equatable, Sendable {
    /// There is no connection, or it dropped.
    case connection
    /// The server did not provide the model.
    case server
    /// What arrived did not pass its check.
    case check
    /// The disk is full.
    case disk

    /// The sentence, which for a full disk says how much room the model needs.
    public func explanation(size: Int64) -> String {
        switch self {
        case .connection: String(localized: "The connection dropped. Try again when you’re online.")
        case .server: String(localized: "Hugging Face didn’t provide the model. Try again later.")
        case .check: String(localized: "The download didn’t pass its check. Try again.")
        case .disk:
            String(localized: "There isn’t enough free space. The model needs \(ModelSize.words(size)).",
                   comment: "The model's size in megabytes, such as 138 MB")
        }
    }
}

/// The model's size as the windows say it: whole megabytes of 1,000,000 bytes, written the same in every locale, so
/// 138,084,519 bytes read "138 MB".
nonisolated public enum ModelSize {
    /// "138 MB": the size to the nearest megabyte.
    public static func words(_ bytes: Int64) -> String {
        String(localized: "\(String(megabytes(bytes, rounding: .toNearestOrAwayFromZero))) MB",
               comment: "A size in whole megabytes")
    }

    /// "62 MB of 138 MB": what has arrived, never rounded up past what is there, and the whole.
    public static func progress(received: Int64, of size: Int64) -> String {
        let whole = megabytes(size, rounding: .toNearestOrAwayFromZero)
        let arrived = min(megabytes(received, rounding: .down), whole)
        return String(localized: "\(String(arrived)) MB of \(String(whole)) MB",
                      comment: "How much of the speech model has arrived, in whole megabytes")
    }

    /// How far a download has come, from 0 to 1.
    public static func fraction(received: Int64, of size: Int64) -> Double {
        guard size > 0 else { return 0 }
        return min(max(Double(received) / Double(size), 0), 1)
    }

    private static func megabytes(_ bytes: Int64, rounding: FloatingPointRoundingRule) -> Int64 {
        Int64((Double(max(bytes, 0)) / 1_000_000).rounded(rounding))
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
    /// the user comes first: the model failing or missing, then the microphone, then Accessibility. Paused
    /// shortcuts and a model that is still preparing or downloading resolve themselves, so they come after.
    public var line: StatusLine {
        switch model {
        case .failed:
            return StatusLine(text: String(localized: "Speech model unavailable"), indicator: .problem,
                              remedy: .retryModel)
        case .notDownloaded(.unavailable):
            return StatusLine(text: String(localized: "No speech model for this Mac yet"), indicator: .problem,
                              remedy: nil)
        case .notDownloaded(.notStarted), .notDownloaded(.failed):
            return StatusLine(text: String(localized: "Speech model not downloaded"), indicator: .problem,
                              remedy: .downloadModel)
        case .preparing, .ready, .notDownloaded(.downloading):
            break
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
        if case .notDownloaded(.downloading) = model {
            return StatusLine(text: String(localized: "Downloading speech model"), indicator: .preparing, remedy: nil)
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
        /// Open the General screen, where the model is downloaded.
        case downloadModel
        case openMicrophoneSettings
        case openAccessibilitySettings

        /// The title of the menu command and the button that apply it.
        public var title: String {
            switch self {
            case .retryModel: String(localized: "Retry")
            case .downloadModel: String(localized: "Download…")
            case .openMicrophoneSettings, .openAccessibilitySettings: String(localized: "Fix…")
            }
        }

        /// What applying it does, for VoiceOver.
        public var hint: String {
            switch self {
            case .retryModel: String(localized: "Loads the speech model again")
            case .downloadModel: String(localized: "Opens the General screen to download the speech model")
            case .openMicrophoneSettings: String(localized: "Opens the General screen to manage microphone access")
            case .openAccessibilitySettings:
                String(localized: "Opens the General screen to manage Accessibility access")
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

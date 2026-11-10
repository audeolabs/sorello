import Foundation

/// What the pill shows (ARCHITECTURE.md, section 8, "States"). The pill knows nothing about the session: the app
/// layer maps its state to this value and hands it to `PillOverlayController.show(_:)`.
public enum PillDisplay: Equatable, Sendable {
    case hidden
    /// Recording, or about to: the wave and the elapsed time.
    case listening(Listening)
    /// The last words are being transcribed, or the model is still preparing.
    case waiting(Waiting)
    /// One short message, with up to three actions.
    case notice(Notice)

    public struct Listening: Equatable, Sendable {
        /// How the dictation was started, which decides how it stops.
        public enum Trigger: Equatable, Sendable {
            /// Hold to Talk: it stops when the key comes up, so the pill takes no clicks.
            case hold
            /// Tap to Toggle: the pill is Stop and a cancel button buds off it.
            case toggle
        }

        public var trigger: Trigger
        /// Prompt style shows a small tag glyph before the time.
        public var promptStyle: Bool
        /// When the dictation started, in monotonic seconds on the clock the overlay was given (the session's).
        /// A new value is a new dictation: its wave starts from rest.
        public var started: TimeInterval

        public init(trigger: Trigger, promptStyle: Bool = false, started: TimeInterval) {
            self.trigger = trigger
            self.promptStyle = promptStyle
            self.started = started
        }
    }

    public enum Waiting: Equatable, Sendable {
        case transcribing
        /// The words "Preparing model" follow the row.
        case preparingModel
    }

    public struct Notice: Equatable, Sendable {
        public enum Tone: Equatable, Sendable {
            case information
            /// The symbol is drawn in ember.
            case error
        }

        /// One of the notice's capsule buttons. Its `id` comes back through `PillOverlayController.onNoticeAction`.
        public struct Action: Equatable, Sendable {
            public var id: String
            public var title: String
            /// Drawn as the white capsule; the others are quiet.
            public var isPrimary: Bool

            public init(id: String, title: String, isPrimary: Bool = false) {
                self.id = id
                self.title = title
                self.isPrimary = isPrimary
            }
        }

        /// Names this notice. A notice with a new id is announced to VoiceOver once and replaces the last one with a
        /// fade; the same id with new text updates it in place.
        public var id: UInt64
        /// An SF Symbols name.
        public var symbol: String
        public var tone: Tone
        /// One line; truncated if it does not fit.
        public var text: String
        /// At most three are shown.
        public var actions: [Action]

        public init(id: UInt64, symbol: String, tone: Tone, text: String, actions: [Action] = []) {
            self.id = id
            self.symbol = symbol
            self.tone = tone
            self.text = text
            self.actions = actions
        }
    }
}

/// The two accessibility display settings the pill honours. The overlay reads them from the system; snapshots set
/// them.
public struct PillAppearance: Equatable, Sendable {
    /// Nothing travels: states cross-fade, the wave stands still at each level, the wait is a still row.
    public var reduceMotion: Bool
    /// A full-point edge, and stronger secondary text.
    public var increaseContrast: Bool

    public init(reduceMotion: Bool = false, increaseContrast: Bool = false) {
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
    }
}

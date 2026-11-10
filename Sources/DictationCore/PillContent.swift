import Foundation

/// What the pill shows, as a pure function of the session's state (ARCHITECTURE.md, section 3, "What the pill
/// shows"). The app maps it to the values `SorelloUI` draws; the voice level comes separately, through `LevelSink`.
public enum PillContent: Sendable, Equatable {
    case hidden
    /// A dictation is starting or recording.
    case listening(ListeningPill)
    /// Dictations are waiting for their transcript or their turn to be inserted. `preparingModel` is true while
    /// the engine is not ready, so the wait is explained.
    case waiting(preparingModel: Bool)
    case notice(Notice)

    /// In order: listening while starting or recording; otherwise an error notice; otherwise waiting while any
    /// dictation remains; otherwise an information notice; otherwise hidden. Nothing is shown while the
    /// permission prompt is up, because the system's prompt is on screen.
    public init(_ state: SessionState) {
        if case .awaitingPermission = state.capture {
            self = .hidden
        } else if let live = state.capture.live {
            self = .listening(ListeningPill(id: live.id, mode: live.mode, style: live.style, since: live.pressTime))
        } else if let notice = state.notice, notice.kind == .error {
            self = .notice(notice)
        } else if state.dictationCount > 0 {
            self = .waiting(preparingModel: state.engine != .ready)
        } else if let notice = state.notice {
            self = .notice(notice)
        } else {
            self = .hidden
        }
    }
}

/// The listening pill's content.
public struct ListeningPill: Sendable, Equatable {
    public var id: DictationID
    /// In toggle mode the pill is Stop and a cancel button buds off it.
    public var mode: TriggerMode
    /// Prompt style shows a small tag glyph before the time.
    public var style: DictationStyle
    /// When the press arrived, on `SessionClock`'s timeline; the elapsed time counts from here.
    public var since: TimeInterval

    public init(id: DictationID, mode: TriggerMode, style: DictationStyle, since: TimeInterval) {
        self.id = id
        self.mode = mode
        self.style = style
        self.since = since
    }
}

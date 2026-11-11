import DictationCore
import SorelloUI

// What the pill draws for what the session says (ARCHITECTURE.md, section 3, "What the pill shows", and section 8,
// "States"). `SorelloUI` knows nothing of the session, so its display value is made here. SorelloUI has an internal
// type of the same name, hence `DictationCore.PillContent` throughout.

extension PillDisplay {
    /// The pill for the session's content. A notice keeps its session id, which lies far below the range the app's
    /// own notices use (`AppNoticeID`), so the two can never be mistaken for each other.
    init(_ content: DictationCore.PillContent) {
        switch content {
        case .hidden:
            self = .hidden
        case .listening(let live):
            self = .listening(Listening(trigger: live.mode == .toggle ? .toggle : .hold,
                                        promptStyle: live.style == .prompt, started: live.since))
        case .waiting(let preparingModel):
            self = .waiting(preparingModel ? .preparingModel : .transcribing)
        case .notice(let notice):
            self = .notice(Notice(id: notice.id.rawValue, symbol: notice.message.symbol,
                                  tone: notice.kind == .error ? .error : .information, text: notice.message.text))
        }
    }
}

extension NoticeMessage {
    /// The SF Symbol beside the notice's line: what the message is about, drawn in ember when it is an error.
    var symbol: String {
        switch self {
        case .busy: "hourglass"
        case .microphoneDenied, .microphoneUnavailable: "mic.slash.fill"
        case .engineFailed, .transcriptionFailed: "exclamationmark.triangle.fill"
        case .nothingHeard: "waveform.slash"
        case .leftOnClipboard: "doc.on.clipboard.fill"
        case .insertionFailed(.commandNotPosted): "return"
        case .insertionFailed: "exclamationmark.triangle.fill"
        }
    }
}

/// Ids for the notices the app shows itself (the dictionary suggestion, and a word that could not be added). They
/// start at 2^63, a range session notices never reach, so a click on an app notice's action is never taken for a
/// session notice's and VoiceOver announces each once.
nonisolated struct AppNoticeID {
    static let base: UInt64 = 1 << 63
    private var next: UInt64 = 0

    /// A new id, never one handed out before.
    mutating func make() -> UInt64 {
        next += 1
        return Self.base | next
    }

    static func isAppNotice(_ id: UInt64) -> Bool { id & base != 0 }
}

import Foundation

// The Run Log's rules for what it shows: when each dictation happened, how it ended and which actions it offers
// (ARCHITECTURE.md, section 7, "Run Log").

/// How a dictation in the Run Log ended.
nonisolated public enum RunLogOutcome: Equatable, Sendable {
    case inserted
    case leftOnClipboard
    case insertionFailed
    case transcriptionFailed

    /// A few words beside the time.
    public var label: String {
        switch self {
        case .inserted: String(localized: "Pasted")
        case .leftOnClipboard: String(localized: "Left on the clipboard")
        case .insertionFailed: String(localized: "Couldn’t paste")
        case .transcriptionFailed: String(localized: "Couldn’t transcribe")
        }
    }

    /// Drawn with the ember symbol rather than a dot.
    public var isProblem: Bool {
        switch self {
        case .inserted, .leftOnClipboard: false
        case .insertionFailed, .transcriptionFailed: true
        }
    }
}

/// One dictation in the Run Log.
nonisolated public struct RunLogItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    /// What the recognizer heard, before any text rule; empty when transcription failed.
    public var heard: String
    /// What was inserted. Empty when transcription failed, and when the dictation was only a command such as
    /// "press enter", which inserts nothing but Return.
    public var text: String
    public var outcome: RunLogOutcome
    /// The recording's length in seconds.
    public var duration: TimeInterval

    public init(id: String, date: Date, heard: String, text: String, outcome: RunLogOutcome, duration: TimeInterval) {
        self.id = id
        self.date = date
        self.heard = heard
        self.text = text
        self.outcome = outcome
        self.duration = duration
    }

    /// What the row shows as the dictation's words.
    public enum Display: Equatable, Sendable {
        /// The inserted text.
        case text(String)
        /// Nothing was inserted but something was heard: a command alone. The row shows what was heard, quoted
        /// and quieter, and says that only a command ran.
        case commandOnly(heard: String)
        /// Nothing was heard or transcribed.
        case none
    }

    public var display: Display {
        if !text.isEmpty { return .text(text) }
        if !heard.isEmpty { return .commandOnly(heard: heard) }
        return .none
    }

    /// Copy is offered only when there are words to copy: the inserted text, or what was heard.
    public var canCopy: Bool { display != .none }

    /// "0:12".
    public var durationLabel: String {
        Duration.seconds(Int(duration.rounded())).formatted(.time(pattern: .minuteSecond))
    }
}

/// When a dictation happened, as the Run Log says it.
nonisolated public enum RunLogTime {
    /// "Just now" under a minute; "5 min ago" under an hour; the time today; "Yesterday, 14:05"; the weekday within
    /// the last week; otherwise the date and time. A date in the future (the clock was changed) reads "Just now".
    public static func label(for date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                             locale: Locale = .autoupdatingCurrent) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return String(localized: "Just now") }
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return String(localized: "\(minutes) min ago")
        }
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        if days == 1 { return String(localized: "Yesterday, \(time)") }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day = days < 7 ? date.formatted(style.weekday(.wide)) : date.formatted(style.day().month(.abbreviated))
        return String(localized: "\(day), \(time)")
    }
}

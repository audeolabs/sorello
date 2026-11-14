import Foundation
import Observation

/// Why a file's transcription failed, as the Transcribe File window says it (ARCHITECTURE.md, section 8, "Windows").
/// None of them carries anything the file holds.
nonisolated public enum TranscribeFailure: Equatable, Sendable, CaseIterable {
    /// The file is in a format Sorello does not read, has no soundtrack, or is damaged.
    case unreadable
    /// The file is not there, is a folder, or may not be read.
    case cannotOpen
    /// The speech model has not been downloaded.
    case modelMissing
    /// No build of the speech model fits this Mac.
    case noModelForThisMac
    /// The speech model could not be loaded.
    case modelUnavailable
    /// The transcription itself failed.
    case failed

    /// The one way to mend the failure from the window, besides choosing another file, if there is one.
    public var remedy: TranscribeRemedy? {
        switch self {
        case .modelMissing: .download
        case .modelUnavailable: .retry
        case .failed: .tryAgain
        case .unreadable, .cannotOpen, .noModelForThisMac: nil
        }
    }
}

/// What a failed transcription offers besides Choose File….
nonisolated public enum TranscribeRemedy: Equatable, Sendable {
    /// Download…: opens the General screen, where the model is downloaded.
    case download
    /// Retry: loads the speech model again, then transcribes the same file.
    case retry
    /// Try Again: transcribes the same file again.
    case tryAgain

    /// The button's title.
    public var title: String {
        switch self {
        case .download: String(localized: "Download…", comment: "Transcribe File: opens General to download the model")
        case .retry: String(localized: "Retry", comment: "Transcribe File: loads the model again, then the file")
        case .tryAgain: String(localized: "Try Again", comment: "Transcribe File: transcribes the same file again")
        }
    }

    /// What the button does, for VoiceOver.
    public var hint: String {
        switch self {
        case .download: String(localized: "Opens General, where the speech model is downloaded")
        case .retry: String(localized: "Loads the speech model again, then transcribes the file")
        case .tryAgain: String(localized: "Transcribes the file again")
        }
    }
}

/// What the Transcribe File window shows (ARCHITECTURE.md, section 8, "Windows"). Each case names the file by its
/// name alone, never its folder; only `done` holds text, and only the window shows it.
nonisolated public enum TranscribeState: Equatable, Sendable {
    /// No file yet: the drop area and Choose File….
    case empty
    /// The speech model is being prepared before `file` can be transcribed.
    case preparing(file: String)
    /// `read` seconds of the file's audio have been read, of `length`. A length of zero or less is not known yet.
    case transcribing(file: String, read: TimeInterval, length: TimeInterval)
    /// The file's text.
    case done(file: String, text: String)
    /// The file was transcribed and no words were heard.
    case nothingHeard(file: String)
    /// The file could not be transcribed.
    case failed(file: String, reason: TranscribeFailure)

    /// Whether the window takes a new file now: not while one is preparing or being transcribed. A drop is accepted,
    /// and the drop area lights up, only when this is true.
    public var takesFiles: Bool {
        switch self {
        case .preparing, .transcribing: false
        case .empty, .done, .nothingHeard, .failed: true
        }
    }

    /// The name of the file the window is showing, if any.
    public var fileName: String? {
        switch self {
        case .empty: nil
        case .preparing(let file), .transcribing(let file, _, _), .done(let file, _), .nothingHeard(let file),
             .failed(let file, _): file
        }
    }
}

/// The words the Transcribe File window shows for its states, kept apart from the view so they can be checked.
nonisolated public enum TranscribeWords {
    /// How much of a file has been read against its length, such as "4:10 of 58:02": minutes and seconds, and hours
    /// for both when the length has them, such as "0:04:10 of 1:18:02". Whole seconds, rounded down, and the amount
    /// read is never shown as more than the length. Nil while the length is not known.
    public static func progress(read: TimeInterval, length: TimeInterval) -> String? {
        let total = wholeSeconds(length)
        guard total > 0 else { return nil }
        let done = min(wholeSeconds(read), total)
        let hours = total >= 3600
        return String(localized: "\(clock(done, hours: hours)) of \(clock(total, hours: hours))",
                      comment: "Transcribe File: how much of the file has been read, such as 4:10 of 58:02")
    }

    /// How far the bar is filled, from 0 to 1, or nil while the length is not known and the bar travels.
    public static func fraction(read: TimeInterval, length: TimeInterval) -> Double? {
        guard length.isFinite, length > 0 else { return nil }
        let read = read.isFinite ? read : 0
        return min(max(read / length, 0), 1)
    }

    /// The failure's one line. The app's name is the installed app's, from its bundle.
    public static func reason(_ failure: TranscribeFailure, appName: String) -> String {
        switch failure {
        case .unreadable: String(localized: "\(appName) can’t read this file",
                                 comment: "Transcribe File: a format it does not read; the app's name")
        case .cannotOpen: String(localized: "This file can’t be opened")
        case .modelMissing: String(localized: "Speech model not downloaded")
        case .noModelForThisMac: String(localized: "No speech model for this Mac yet")
        case .modelUnavailable: String(localized: "Speech model unavailable")
        case .failed: String(localized: "Couldn’t transcribe this file")
        }
    }

    /// A second line under the reason, where one helps: the formats Sorello reads, under a file it cannot.
    public static func detail(_ failure: TranscribeFailure) -> String? {
        guard failure == .unreadable else { return nil }
        return String(localized: "It reads WAV, AIFF, CAF, FLAC, MP3, M4A and Ogg, and the sound of MP4 and MOV videos.",
                      comment: "Transcribe File: the formats it reads, under a file it cannot read")
    }

    /// The words while the model prepares.
    public static var preparing: String { String(localized: "Preparing speech model") }
    /// The words in the empty window's drop area.
    public static var dropPrompt: String { String(localized: "Drop an audio or video file") }
    /// The words in place of the text when no words were heard.
    public static var nothingHeard: String { String(localized: "No speech heard") }
    /// The window's title.
    public static var title: String { String(localized: "Transcribe File") }

    private static func wholeSeconds(_ value: TimeInterval) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, Double(Int.max / 2)).rounded(.down))
    }

    private static func clock(_ seconds: Int, hours: Bool) -> String {
        let minutes = seconds / 60 % 60, rest = seconds % 60
        guard hours else { return String(format: "%d:%02d", seconds / 60, rest) }
        return String(format: "%d:%02d:%02d", seconds / 3600, minutes, rest)
    }
}

/// What the Transcribe File window's controls ask of the app layer. The window never reads a file, transcribes,
/// copies or saves itself.
public struct TranscribeActions {
    /// Show the system's file picker as a sheet on the window.
    public var chooseFile: () -> Void
    /// A file was dropped on the window while it takes files. Only a single file's address is ever given.
    public var dropFile: (URL) -> Void
    /// Stop what is running and go back to the empty window.
    public var cancel: () -> Void
    /// Put the text on the clipboard.
    public var copy: () -> Void
    /// Write the text to a plain text file, where the user chooses.
    public var save: () -> Void
    /// Open the General screen, where the speech model is downloaded.
    public var download: () -> Void
    /// Load the speech model again, then transcribe the same file.
    public var retry: () -> Void
    /// Transcribe the same file again.
    public var tryAgain: () -> Void

    /// Actions that each do nothing unless given.
    public init(chooseFile: @escaping () -> Void = {}, dropFile: @escaping (URL) -> Void = { _ in },
                cancel: @escaping () -> Void = {}, copy: @escaping () -> Void = {}, save: @escaping () -> Void = {},
                download: @escaping () -> Void = {}, retry: @escaping () -> Void = {},
                tryAgain: @escaping () -> Void = {}) {
        self.chooseFile = chooseFile
        self.dropFile = dropFile
        self.cancel = cancel
        self.copy = copy
        self.save = save
        self.download = download
        self.retry = retry
        self.tryAgain = tryAgain
    }

    /// Runs the action for `remedy`.
    public func perform(_ remedy: TranscribeRemedy) {
        switch remedy {
        case .download: download()
        case .retry: retry()
        case .tryAgain: tryAgain()
        }
    }
}

/// The Transcribe File window's values. The app layer keeps `state` current as the file is transcribed.
@Observable
public final class TranscribeModel {
    /// The app's name as installed, from the bundle, for the line under a file it cannot read.
    public var appName: String
    /// What the window shows.
    public var state: TranscribeState
    /// What the window's controls ask of the app layer.
    public var actions: TranscribeActions

    /// The window's values.
    public init(appName: String, state: TranscribeState = .empty, actions: TranscribeActions = TranscribeActions()) {
        self.appName = appName
        self.state = state
        self.actions = actions
    }
}

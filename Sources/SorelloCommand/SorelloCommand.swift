import DictationCore
import DictionaryKit
import FileTranscription
import Foundation
import Persistence
import SpeechEngine
import Synchronization
import TextRules

/// What the transcriber is made from: the app's model, and the dictionary's words to decode with.
public struct CommandModel: Sendable {
    /// The build the app's pin gives this Mac, in the app's store or carried by the app.
    public let model: PinnedModel
    /// The dictionary's words that apply everywhere, or none for `--no-dictionary`.
    public let dictionary: DictionarySnapshot
}

/// Everything the command reads from and writes to the world, so tests can give it their own.
public struct CommandEnvironment: Sendable {
    /// The arguments after the command's own name.
    public var arguments: [String]
    /// The path the command was started by, which may be a symbolic link; the command follows it to find its app.
    public var executablePath: String
    /// The user's `Library/Application Support`, under which each app keeps its data.
    public var applicationSupport: URL
    /// An app's preferences, by its bundle identifier; nil when they cannot be had.
    public var preferences: @Sendable (String) -> UserDefaults?
    /// Makes the transcriber for the app's model. The command passes `SorelloCommand.engineTranscriber`.
    public var makeTranscriber: @Sendable (CommandModel) -> any FileTranscribing
    /// Waits for a while, for the note that says the model is still preparing; it may return early when cancelled.
    public var sleep: @Sendable (Duration) async -> Void
    /// Writes to standard output.
    public var standardOutput: @Sendable (String) -> Void
    /// Writes to standard error.
    public var standardError: @Sendable (String) -> Void

    public init(arguments: [String], executablePath: String, applicationSupport: URL,
                preferences: @escaping @Sendable (String) -> UserDefaults?,
                makeTranscriber: @escaping @Sendable (CommandModel) -> any FileTranscribing,
                sleep: @escaping @Sendable (Duration) async -> Void,
                standardOutput: @escaping @Sendable (String) -> Void,
                standardError: @escaping @Sendable (String) -> Void) {
        self.arguments = arguments
        self.executablePath = executablePath
        self.applicationSupport = applicationSupport
        self.preferences = preferences
        self.makeTranscriber = makeTranscriber
        self.sleep = sleep
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// The `sorello` command (ARCHITECTURE.md, section 10, "The command"): `sorello transcribe <file>` writes a file's text
/// to standard output with the model, dictionary and text rules of the app it is in, whether that app is running or
/// not. It never downloads, never writes to the app's data, and keeps no log: standard output carries the text and
/// nothing else, and every message goes to standard error.
public enum SorelloCommand {
    /// The exit statuses, as `sysexits.h` names them.
    public enum Status {
        public static let ok: Int32 = 0
        /// EX_USAGE: the arguments are wrong.
        public static let usage: Int32 = 64
        /// EX_DATAERR: Sorello cannot read the file.
        public static let unreadable: Int32 = 65
        /// EX_NOINPUT: the file cannot be opened.
        public static let cannotOpen: Int32 = 66
        /// EX_UNAVAILABLE: no app around the command, the model is not downloaded, or no model fits this Mac.
        public static let unavailable: Int32 = 69
        /// EX_SOFTWARE: the model could not be loaded, or the transcription failed.
        public static let failed: Int32 = 70
    }

    /// How long the model may prepare before the command says it is preparing.
    public static let preparingNoteDelay: Duration = .seconds(2)

    /// Runs the command once and returns its exit status.
    @MainActor
    public static func run(_ environment: CommandEnvironment) async -> Int32 {
        let say: @Sendable (String) -> Void = { message in environment.standardError("sorello: \(message)\n") }
        let request = CommandRequest(environment.arguments)
        switch request {
        case .help:
            environment.standardOutput(CommandRequest.usage)
            return Status.ok
        case .wrong(let reason):
            if let reason { say(reason) }
            environment.standardError(CommandRequest.usage)
            return Status.usage
        case .version, .transcribe:
            break
        }
        guard let app = CommandApp(executablePath: environment.executablePath) else {
            say(String(localized: """
                can't find the Sorello app this command belongs to. Run Contents/Helpers/sorello inside the app, \
                or a symbolic link to it.
                """))
            return Status.unavailable
        }
        guard case .transcribe(let file, let usesDictionary, let usesRules) = request else {
            environment.standardOutput("\(app.name) \(app.version) (\(app.build))\n")
            return Status.ok
        }

        guard let pin = try? ModelPin(contentsOf: app.resources.appendingPathComponent("model.lock.json")),
              let paths = try? AppPaths(bundleIdentifier: app.bundleIdentifier,
                                        applicationSupport: environment.applicationSupport) else {
            say(String(localized: "\(app.name) is damaged: its speech model's pin can't be read. Install it again."))
            return Status.unavailable
        }
        let carried = app.resources.appendingPathComponent("Model", isDirectory: true)
        let carries = FileManager.default.fileExists(atPath: carried.appendingPathComponent(ModelPin.manifestName).path)
        let model = PinnedModel(pin: pin, storeDirectory: paths.modelsDirectory, carriedDirectory: carries ? carried : nil)

        var dictionary = DictionarySnapshot.empty
        if usesDictionary {
            if let read = DictionaryStore.readWithoutChanging(paths.dictionaryFile, encoder: model.vocabulary()) {
                dictionary = DictionarySnapshot(revision: 1, entries: read.decodingWords(for: nil).entries)
            } else {
                say(String(localized: "can't read \(app.name)'s dictionary (dictionary.json); transcribing without it"))
            }
        }
        var rules: TextRuleOptions?
        if usesRules {
            let defaults: UserDefaults
            if let preferences = environment.preferences(app.bundleIdentifier) {
                defaults = preferences
            } else {
                say(String(localized: "can't read \(app.name)'s settings; using the default text rules"))
                defaults = UserDefaults(suiteName: "\(app.bundleIdentifier).command-defaults") ?? .standard
            }
            var macros: [VoiceMacro] = []
            if let read = MacroStore.readWithoutChanging(paths.macrosFile) {
                macros = read
            } else {
                say(String(localized: "can't read \(app.name)'s macros (macros.json); transcribing without them"))
            }
            rules = TextRuleOptions(settings: SettingsStore(defaults: defaults), macros: macros)
        }

        let transcriber = environment.makeTranscriber(CommandModel(model: model, dictionary: dictionary))
        let note = PreparingNote(sleep: environment.sleep) {
            say(String(localized: "preparing the speech model; the first time on this Mac this can take a few minutes"))
        }
        let text: String
        do {
            text = try await transcriber.transcribe(URL(fileURLWithPath: file), rules: rules, progress: note.heard)
            note.end()
        } catch {
            note.end()
            let (status, message) = failure(error, file: file, app: app)
            say(message)
            return status
        }
        if !text.isEmpty { environment.standardOutput(text + "\n") }
        return Status.ok
    }

    /// The transcriber the shipped command uses: the speech engine, made as the app makes its own, over the app's
    /// model, with `model.dictionary` for every file.
    public static func engineTranscriber(_ model: CommandModel) -> any FileTranscribing {
        let words = model.dictionary
        let engine = SpeechEngine(model: model.model, dictionary: { _ in words })
        return FileTranscriber(engine: engine, modelFitsThisMac: model.model.build != nil)
    }

    private static func failure(_ failure: FileTranscriptionFailure, file: String,
                                app: CommandApp) -> (Int32, String) {
        switch failure {
        case .cannotOpen:
            (Status.cannotOpen, String(localized: "can't open \(file)"))
        case .unreadable:
            (Status.unreadable, String(localized: """
                can't read \(file). Sorello reads WAV, AIFF, CAF, FLAC, MP3, M4A and Ogg files, and the sound of MP4 \
                and MOV videos.
                """))
        case .modelMissing:
            (Status.unavailable, String(localized: """
                the speech model is not downloaded. Open \(app.name) and download it there.
                """))
        case .noModelForThisMac:
            (Status.unavailable, String(localized: "\(app.name) has no speech model for this Mac yet."))
        case .modelUnavailable:
            (Status.failed, String(localized: "the speech model could not be loaded. Open \(app.name) to try again."))
        case .failed:
            (Status.failed, String(localized: "couldn't transcribe \(file)"))
        case .cancelled:
            (Status.failed, String(localized: "the transcription was stopped"))
        }
    }
}

/// Says once, after a while, that the model is still preparing (ARCHITECTURE.md, section 10, "The command", "Its
/// model"). A transcription reports `preparingModel` when it has to wait for the model; if it is still waiting when
/// the delay has passed, the note is written, and once it has begun transcribing, or has ended, it never is: not even
/// by a timer that had already decided to write it.
final class PreparingNote: Sendable {
    private struct State {
        var waiting = false
        var done = false
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let sleep: @Sendable (Duration) async -> Void
    private let write: @Sendable () -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void, write: @escaping @Sendable () -> Void) {
        self.sleep = sleep
        self.write = write
    }

    /// What the transcription reports, from any thread.
    var heard: @Sendable (FileTranscriptionProgress) -> Void {
        { [self] progress in
            switch progress {
            case .preparingModel: begin()
            case .transcribing: end()
            }
        }
    }

    /// The model is not ready: the delay starts, once.
    private func begin() {
        state.withLock { state in
            guard !state.waiting, !state.done else { return }
            state.waiting = true
            state.timer = Task { [self] in
                await sleep(SorelloCommand.preparingNoteDelay)
                // Written under the lock `end` takes, so once `end` has returned it never is.
                self.state.withLock { state in
                    guard !state.done else { return }
                    state.done = true
                    write()
                }
            }
        }
    }

    /// Transcribing has begun, or the transcription has ended: the note is never written now.
    func end() {
        let timer = state.withLock { state in
            state.done = true
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }
}

import FileTranscription
import Foundation
import SorelloUI
import TextRules

/// What the Transcribe File window asks of the rest of the app: the window itself, its sheets, the clipboard and the
/// General screen. The shell gives the real ones; tests record what was asked.
struct TranscribePorts {
    /// Brings the window forward, opening it if it is closed.
    var show: @MainActor () -> Void = {}
    /// Shows the system's file picker as a sheet on the window, offering audio and video files, and hands over the
    /// file the user chose. Choosing nothing hands over nothing.
    var chooseFile: @MainActor (_ chosen: @escaping @MainActor (URL) -> Void) -> Void = { _ in }
    /// Shows the system's save panel as a sheet on the window, offering `name`, and writes `text` where the user
    /// chooses, as plain UTF-8 text.
    var save: @MainActor (_ text: String, _ name: String) -> Void = { _, _ in }
    /// Puts `text` on the clipboard.
    var copy: @MainActor (String) -> Void = { _ in }
    /// Opens the main window's General screen, where the model is downloaded.
    var openGeneral: @MainActor () -> Void = {}
    /// Asks the engine to prepare the model again, and returns once that attempt has ended, however it ended.
    var prepareModel: @Sendable () async -> Void = {}
}

/// The Transcribe File window's model (ARCHITECTURE.md, section 5, "Transcribing a file", and section 8, "Windows").
/// It runs one transcription at a time through `FileTranscribing`, the path the `sorello` command takes too, in a
/// task it owns, and turns what that reports into the window's `TranscribeState`.
///
/// A file dropped on the window, chosen in its picker, or opened with Sorello from the Finder comes in through `take`,
/// and is refused while another is preparing or being transcribed: the window only comes forward. A drop's file and
/// a picker's choice arrive a moment after the user acts; one that arrives once the window has closed is not taken,
/// so nothing runs, and no text is held, without the window. The text rules are
/// read when a transcription starts and kept for it. Progress, reported on any thread, reaches the window in order on
/// the main actor. Cancel, closing the window, and taking another file cancel the task and forget the text; a
/// cancelled transcription changes nothing afterwards.
@MainActor
final class TranscribeBinding {
    /// What the window draws.
    let model: TranscribeModel
    private let transcriber: any FileTranscribing
    private let rules: @MainActor () -> TextRuleOptions
    private let ports: TranscribePorts
    /// The file the window shows, for Retry and Try Again; nil when it shows none.
    private var file: URL?
    /// The transcription under way, if any.
    private var running: Task<Void, Never>?
    /// Whether the window is open: from the time the binding brings it forward until it closes.
    private(set) var windowIsOpen = false
    /// Hears every state the window is given, in order. The self-test prints them.
    var stateChanged: (@MainActor (TranscribeState) -> Void)?

    /// `rules`: the user's text rules as they are now, read once as each transcription starts.
    init(appName: String, transcriber: any FileTranscribing, rules: @escaping @MainActor () -> TextRuleOptions,
         ports: TranscribePorts) {
        self.transcriber = transcriber
        self.rules = rules
        self.ports = ports
        model = TranscribeModel(appName: appName)
        model.actions = TranscribeActions(
            chooseFile: { [weak self] in self?.chooseFile() },
            dropFile: { [weak self] in self?.take($0) },
            cancel: { [weak self] in self?.cancel() },
            copy: { [weak self] in self?.copy() },
            save: { [weak self] in self?.save() },
            download: { [weak self] in self?.ports.openGeneral() },
            retry: { [weak self] in self?.retry() },
            tryAgain: { [weak self] in self?.tryAgain() })
    }

    /// The menu's Transcribe File…: the window comes forward, opening if it is closed, and shows its file picker
    /// unless a file is being transcribed there.
    func open() {
        windowIsOpen = true
        ports.show()
        if model.state.takesFiles { chooseFile() }
    }

    /// A file opened with Sorello from the Finder, or dropped on its Dock icon: the window comes forward and takes
    /// it, unless it is busy with another.
    func open(file: URL) {
        windowIsOpen = true
        ports.show()
        take(file)
    }

    /// Takes `file` and transcribes it, unless the window has closed, or another file is preparing or being
    /// transcribed; then the window only comes forward.
    func take(_ file: URL) {
        guard windowIsOpen else { return }
        guard model.state.takesFiles else {
            ports.show()
            return
        }
        begin(file, preparingFirst: false)
    }

    /// The window was closed: whatever it was doing stops, and its text is forgotten.
    func windowClosed() {
        windowIsOpen = false
        stop()
    }

    // MARK: - Actions

    private func chooseFile() {
        ports.chooseFile { [weak self] file in self?.take(file) }
    }

    private func cancel() {
        stop()
    }

    private func copy() {
        guard case .done(_, let text) = model.state else { return }
        ports.copy(text)
    }

    private func save() {
        guard case .done(let name, let text) = model.state else { return }
        ports.save(text, Self.textFileName(for: name))
    }

    private func retry() {
        guard let file, model.state.takesFiles else { return }
        begin(file, preparingFirst: true)
    }

    private func tryAgain() {
        guard let file, model.state.takesFiles else { return }
        begin(file, preparingFirst: false)
    }

    /// The name Save… offers: the file's name with `.txt` in place of its extension.
    nonisolated static func textFileName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + ".txt"
    }

    // MARK: - Running

    /// Starts transcribing `file`, after asking the engine to prepare again when `preparingFirst`.
    private func begin(_ file: URL, preparingFirst: Bool) {
        running?.cancel()
        self.file = file
        let name = file.lastPathComponent
        let rules = self.rules()
        let transcriber = self.transcriber, prepare = ports.prepareModel
        show(preparingFirst ? .preparing(file: name) : .transcribing(file: name, read: 0, length: 0))
        running = Task { [weak self] in
            if preparingFirst {
                await prepare()
                guard !Task.isCancelled else { return }
            }
            let (updates, sink) = AsyncStream.makeStream(of: FileTranscriptionProgress.self,
                                                         bufferingPolicy: .bufferingNewest(16))
            async let outcome = Self.transcribe(file, rules: rules, with: transcriber, reporting: sink)
            for await progress in updates {
                guard !Task.isCancelled else { break }
                self?.progressed(progress, name: name)
            }
            let result = await outcome
            guard !Task.isCancelled else { return }
            self?.finished(result, name: name)
        }
    }

    /// Runs the transcription off the main actor, passing its progress on, and says how it ended.
    nonisolated private static func transcribe(_ file: URL, rules: TextRuleOptions?,
                                               with transcriber: any FileTranscribing,
                                               reporting sink: AsyncStream<FileTranscriptionProgress>.Continuation)
        async -> Result<String, FileTranscriptionFailure> {
        defer { sink.finish() }
        do {
            return .success(try await transcriber.transcribe(file, rules: rules) { _ = sink.yield($0) })
        } catch {
            return .failure(error)
        }
    }

    private func progressed(_ progress: FileTranscriptionProgress, name: String) {
        guard !model.state.takesFiles else { return }
        switch progress {
        case .preparingModel:
            show(.preparing(file: name))
        case .transcribing(let read, let length):
            show(.transcribing(file: name, read: read, length: length))
        }
    }

    private func finished(_ result: Result<String, FileTranscriptionFailure>, name: String) {
        running = nil
        switch result {
        case .success(let text):
            let heard = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            show(heard ? .done(file: name, text: text) : .nothingHeard(file: name))
        case .failure(let failure):
            show(.failed(file: name, reason: Self.reason(failure)))
        }
    }

    /// Cancels what is running and empties the window.
    private func stop() {
        running?.cancel()
        running = nil
        file = nil
        show(.empty)
    }

    private func show(_ state: TranscribeState) {
        guard model.state != state else { return }
        model.state = state
        stateChanged?(state)
    }

    /// The window's words for a failure. A transcription cancelled without the window asking (it never asks without
    /// stopping first) is offered again with Try Again.
    nonisolated static func reason(_ failure: FileTranscriptionFailure) -> TranscribeFailure {
        switch failure {
        case .cannotOpen: .cannotOpen
        case .unreadable: .unreadable
        case .modelMissing: .modelMissing
        case .noModelForThisMac: .noModelForThisMac
        case .modelUnavailable: .modelUnavailable
        case .failed, .cancelled: .failed
        }
    }
}

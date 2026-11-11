import DictionaryKit
import Foundation
import SpeechEngine

/// The speech model's download as the app uses it (ARCHITECTURE.md, section 5, "Getting the model"). The app makes
/// one, beside the engine, and starts it only when the user presses Download; the tests give a fake.
nonisolated protocol ModelDownloading: AnyObject, Sendable {
    /// The build's size in bytes; 0 when no build fits this Mac.
    var size: Int64 { get }
    /// Where the download stands now.
    var current: ModelDownloadState { get }
    /// The current state, then every change.
    func states() -> AsyncStream<ModelDownloadState>
    /// Starts the download, unless one is running, the model is here or there is none for this Mac.
    func start()
    /// Stops the download; what arrived is kept for the next start.
    func cancel()
    /// Looks again at whether the model is on this Mac, after the engine found it missing.
    func refresh()
    /// The model's vocabulary, for the dictionary, once the model is on this Mac.
    func vocabulary() -> BPEEncoder?
}

/// The download of the build the app's pin lists for this Mac, into the app's store.
nonisolated final class PinnedDownload: ModelDownloading {
    let model: PinnedModel
    let download: ModelDownload

    /// The download of `model`, naming itself as Sorello `version`.
    init(model: PinnedModel, version: String) {
        self.model = model
        download = ModelDownload(model: model, version: version)
    }

    var size: Int64 { download.size }
    var current: ModelDownloadState { download.current }
    func states() -> AsyncStream<ModelDownloadState> { download.states() }
    func start() { download.start() }
    func cancel() { download.cancel() }
    func refresh() { download.refresh() }
    func vocabulary() -> BPEEncoder? { model.vocabulary() }
}

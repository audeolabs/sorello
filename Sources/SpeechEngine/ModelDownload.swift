import DictationCore
import Foundation
import Synchronization

/// Where the model's download stands, as the app shows it.
public enum ModelDownloadState: Sendable, Equatable {
    /// No build of the model fits this Mac, so there is nothing to download.
    case unavailable
    /// The model is not on this Mac and no download is running. What an earlier run left is kept for the next.
    case absent
    /// Bytes of the build on disk so far, out of `ModelDownload.size`.
    case downloading(received: Int64)
    /// The last run stopped for this reason. Nothing it fetched is loaded; the next run goes on from it.
    case failed(ModelDownloadFailure)
    /// The model is on this Mac: in the store, or carried by the app.
    case installed
}

/// What one run of the download did, for the verification tools.
public struct ModelDownloadReport: Sendable, Equatable {
    /// How it ended: `installed`, `failed`, or `absent` when it was cancelled.
    public var state: ModelDownloadState
    /// Bytes that came over the network.
    public var fetched: Int64
    /// How long it took.
    public var seconds: Double
    /// For each file continued with a range request, the byte it went on from.
    public var continuedFrom: [Int64]
    /// Files a server sent again from their start, although a range was asked for.
    public var startedAgain: Int
    /// The model was on this Mac already, so nothing was fetched.
    public var wasAlreadyThere: Bool
}

/// The speech model's download (ARCHITECTURE.md, section 5, "Getting the model"): the one network connection Sorello
/// makes. It starts only when `start` is called, which the app does only when the user presses Download, and never
/// again by itself: not at launch, not on a timer, not after a failure or a quit. One run at a time; a second `start`
/// joins the first. What the app shows is `state`: the bytes received, or one of four reasons.
public final class ModelDownload: Sendable {
    /// The whole build's size, from the pin; 0 when no build fits this Mac.
    public let size: Int64

    private struct State {
        var current: ModelDownloadState
        var run: Task<ModelDownloadReport, Never>?
        var pace = ProgressPace()
        var subscribers: [UUID: AsyncStream<ModelDownloadState>.Continuation] = [:]
    }

    private let model: PinnedModel
    private let version: String
    private let makeTransport: @Sendable () -> any DownloadTransport
    private let clock: any SessionClock
    private let freeSpace: @Sendable (URL) -> Int64?
    private let state: Mutex<State>

    /// The download of `model`'s build, over the network, announcing itself as Sorello `version`.
    public convenience init(model: PinnedModel, version: String) {
        self.init(model: model, version: version, transport: { ModelDownloader() }, clock: SystemSessionClock(),
                  freeSpace: Self.freeSpace(at:))
    }

    /// `transport` makes what carries one run's requests; the tests pass a server of their own.
    init(model: PinnedModel, version: String, transport: @escaping @Sendable () -> any DownloadTransport,
         clock: any SessionClock, freeSpace: @escaping @Sendable (URL) -> Int64?) {
        self.model = model
        self.version = version
        makeTransport = transport
        self.clock = clock
        self.freeSpace = freeSpace
        size = model.build?.bytes ?? 0
        state = Mutex(State(current: Self.resting(model)))
    }

    /// Where the download stands now.
    public var current: ModelDownloadState { state.withLock { $0.current } }

    /// The current state, then every change, for each caller separately. Progress comes at most ten times a second.
    public func states() -> AsyncStream<ModelDownloadState> {
        let (stream, continuation) = AsyncStream<ModelDownloadState>.makeStream()
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.current)
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Starts the download, unless one is running, the model is here, or no build fits this Mac.
    public func start() {
        _ = begin()
    }

    /// Starts the download, or joins the run in progress, and returns how it went. When there was nothing to do, says
    /// so without fetching anything.
    @discardableResult
    public func download() async -> ModelDownloadReport {
        if let run = begin() { return await run.value }
        let now = current
        return ModelDownloadReport(state: now, fetched: 0, seconds: 0, continuedFrom: [], startedAgain: 0,
                                   wasAlreadyThere: now == .installed)
    }

    /// Stops the run at once. What it fetched stays for the next.
    public func cancel() {
        state.withLock { $0.run }?.cancel()
    }

    /// Looks again at whether the model is on this Mac, while no run is going: the engine may have found the stored
    /// copy damaged and removed it.
    public func refresh() {
        let resting = Self.resting(model)
        state.withLock { state in
            guard state.run == nil else { return }
            switch (state.current, resting) {
            case (.installed, _), (_, .installed): publish(resting, in: &state)
            default: break
            }
        }
    }

    // MARK: - Running

    private static func resting(_ model: PinnedModel) -> ModelDownloadState {
        guard model.build != nil else { return .unavailable }
        return model.isOnThisMac ? .installed : .absent
    }

    /// The run in progress, or a new one; nil when there is nothing to download.
    private func begin() -> Task<ModelDownloadReport, Never>? {
        guard let build = model.build else { return nil }
        if case .installed = current, model.isOnThisMac { return nil }
        let received = ModelStore(root: model.storeDirectory).downloadedBytes(build.manifestSHA256)
        return state.withLock { state -> Task<ModelDownloadReport, Never>? in
            if let run = state.run { return run }
            let run = Task { await self.perform(build) }
            state.run = run
            state.pace = ProgressPace()
            publish(.downloading(received: received), in: &state)
            return run
        }
    }

    private func perform(_ build: ModelPin.Build) async -> ModelDownloadReport {
        let started = ContinuousClock.now
        let fetch = ModelFetch(pin: model.pin, build: build, store: ModelStore(root: model.storeDirectory),
                               transport: makeTransport(), clock: clock, version: version, freeSpace: freeSpace,
                               progress: { [weak self] bytes in self?.progressed(bytes) })
        let (ending, tally) = await fetch.run()
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let ended: ModelDownloadState
        switch ending {
        case .installed:
            ended = .installed
            Diagnostics.record("model.downloaded", ["bytes": Double(tally.fetched), "seconds": seconds])
        case .failed(let failure):
            ended = .failed(failure)
            Diagnostics.record("model.downloadFailed", ["reason": Self.code(failure), "bytes": Double(tally.fetched),
                                                        "seconds": seconds])
        case .cancelled:
            ended = .absent
            Diagnostics.record("model.downloadCancelled", ["bytes": Double(tally.fetched), "seconds": seconds])
        }
        state.withLock { state in
            state.run = nil
            publish(ended, in: &state)
        }
        return ModelDownloadReport(state: ended, fetched: tally.fetched, seconds: seconds,
                                   continuedFrom: tally.continuedFrom, startedAgain: tally.startedAgain,
                                   wasAlreadyThere: tally.wasAlreadyThere)
    }

    private func progressed(_ bytes: Int64) {
        let now = clock.now
        state.withLock { state in
            guard state.run != nil, case .downloading = state.current, state.pace.admits(at: now) else { return }
            publish(.downloading(received: bytes), in: &state)
        }
    }

    private func publish(_ next: ModelDownloadState, in state: inout State) {
        guard state.current != next else { return }
        state.current = next
        for continuation in state.subscribers.values { continuation.yield(next) }
    }

    /// A reason as a number, for diagnostics, which carry no words.
    private static func code(_ failure: ModelDownloadFailure) -> Double {
        switch failure {
        case .connection: 1
        case .server: 2
        case .check: 3
        case .disk: 4
        }
    }

    /// The bytes free on the volume holding `url`, for files the user needs, when the system says.
    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

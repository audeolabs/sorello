import Foundation
import Synchronization

// The correction watch (DESIGN §3.5): after a dictation is pasted, the pasted span is followed in the destination
// field for up to 60 s, and each settled edit is reported so the app can check it against the dictation's audio.
// Accessibility is reached only through `TextFieldReading`. Text read here is held only while the watch runs.
// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.

/// A monotonic generation shared by every thread, so work from a cancelled watch is ignored even while a read is in
/// flight.
final class CorrectionWatchGeneration: Sendable {
    private let value = Mutex<UInt64>(0)

    @discardableResult
    func advance() -> UInt64 {
        value.withLock { value in
            value += 1
            return value
        }
    }

    var current: UInt64 { value.withLock { $0 } }

    func isCurrent(_ generation: UInt64) -> Bool { value.withLock { $0 == generation } }

    /// Advances only if `generation` is still current; returns the new value.
    func advance(from generation: UInt64) -> UInt64? {
        value.withLock { value in
            guard value == generation else { return nil }
            value += 1
            return value
        }
    }
}

/// Where a dictation was pasted, bound to one watch. The inserter reads the destination field and its selection
/// before it pastes (ARCHITECTURE.md, section 4); the app turns that reading into an anchor, and the watch follows
/// the paste from there. The watcher never looks for the focused field itself.
public struct CorrectionAnchor: Sendable {
    let target: TextFieldTarget
    /// The watch this anchor belongs to; it is stale once the watcher is cancelled.
    public let generation: UInt64
    /// Where the selection started just before the paste, if it could be read: a retried start must find the paste
    /// there.
    let insertionPoint: Int?
}

/// Watches one paste at a time on its own serial queue, so blocking Accessibility reads never occupy the cooperative
/// thread pool: one read in flight, a 0.5 s poll for at most 60 s, no observers.
///
/// Every watch has a generation. Cancelling (a new recording, the setting turned off, a dictionary change, quitting)
/// makes the current one stale at once, from any thread, so nothing read for it is used afterwards. Edits are
/// delivered to `onEdit` on the main actor, only while their watch is current; using one means claiming the watch
/// first (`claim`), which ends it, so there is at most one suggestion per paste.
public actor CorrectionWatcher {
    /// When the start is tried, in seconds after the paste was posted. A browser can update the field's
    /// Accessibility text a moment late, so a start that fails because the field still shows the old text or a read
    /// fails is tried at the next one.
    public static let startAttempts: [TimeInterval] = [0.15, 0.4, 1, 2]
    public static let pollInterval: TimeInterval = 0.5

    private let queue = DispatchSerialQueue(label: "sorello.correction-watch", qos: .utility)
    private let reader: any TextFieldReading
    private let attempts: [TimeInterval]
    private let generation = CorrectionWatchGeneration()
    private let onEdit: @MainActor @Sendable (CorrectionEdit, Bool, UInt64) -> Void
    private let onAbandon: @MainActor @Sendable () -> Void
    private var session: CorrectionWatchSession?
    private var sessionGeneration: UInt64?
    private var polling: Task<Void, Never>?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - `onEdit`: an edit to check, whether it is the watch's last (`isLast`), and the watch's generation, which
    ///   must be claimed before a result for it is used.
    /// - `onAbandon`: the field turned secure or Accessibility permission was lost, so edits already reported must not
    ///   be used. The watch was already made stale; the app stops their checks.
    public init(reader: any TextFieldReading, startAttempts: [TimeInterval] = CorrectionWatcher.startAttempts,
                onEdit: @escaping @MainActor @Sendable (_ edit: CorrectionEdit, _ isLast: Bool, _ watch: UInt64) -> Void,
                onAbandon: @escaping @MainActor @Sendable () -> Void) {
        precondition(!startAttempts.isEmpty, "At least one start attempt")
        self.reader = reader
        attempts = startAttempts
        self.onEdit = onEdit
        self.onAbandon = onAbandon
    }

    /// The generation a finished dictation's paste is bound to. Any cancel makes it stale.
    public nonisolated var currentGeneration: UInt64 { generation.current }

    public nonisolated func isCurrent(_ watch: UInt64) -> Bool { generation.isCurrent(watch) }

    /// Binds the field a dictation is about to be pasted into to a new watch, only if `expected` (the generation
    /// when the dictation's text was composed) is still current; a stale one gets nil and touches nothing. Any
    /// earlier watch ends. `target` and `insertionPoint` (where the selection started, if it was read) come from the
    /// inserter's own reading of the field.
    public nonisolated func anchor(target: TextFieldTarget, insertionPoint: Int?,
                                   expecting expected: UInt64) -> CorrectionAnchor? {
        guard let token = generation.advance(from: expected) else { return nil }
        Task { await self.stop() }
        return CorrectionAnchor(target: target, generation: token, insertionPoint: insertionPoint)
    }

    /// Begins watching about 150 ms after the paste was posted, trying again up to 2 s after it while the field has
    /// not caught up. `correctionID` is the speech result's, and comes back in every edit.
    public nonisolated func start(_ anchor: CorrectionAnchor, pasted: String, correctionID: UInt64) {
        let postedAt = ContinuousClock.now
        Task { await self.attemptStarts(anchor, pasted: pasted, correctionID: correctionID, postedAt: postedAt) }
    }

    /// Discards the current watch without finalizing. Safe from any thread.
    public nonisolated func cancel() {
        generation.advance()
        Task { await self.stop() }
    }

    /// Ends watch `watch` to use a result for it, in one atomic step: false, changing nothing, if that watch is no
    /// longer current (abandoned, or cancelled). Safe from any thread.
    public nonisolated func claim(_ watch: UInt64) -> Bool {
        guard generation.advance(from: watch) != nil else { return false }
        Task { await self.stop() }
        return true
    }

    private func attemptStarts(_ anchor: CorrectionAnchor, pasted: String, correctionID: UInt64,
                               postedAt: ContinuousClock.Instant) async {
        let watch = anchor.generation
        for (attempt, delay) in attempts.enumerated() {
            try? await Task.sleep(until: postedAt + .seconds(delay), clock: .continuous)
            guard generation.isCurrent(watch) else { return }
            // A retry must find the paste where the selection started, so a caret moved meanwhile cannot bind it to
            // an older copy of the text.
            let begun = CorrectionWatchSession.begin(
                reader: reader, target: anchor.target, pasted: pasted, correctionID: correctionID, now: Self.uptime(),
                expectedStart: attempt == 0 ? nil : anchor.insertionPoint,
                isCancelled: { [generation] in !generation.isCurrent(watch) }, clock: { Self.uptime() })
            switch begun {
            case .success(let session):
                install(session, watch: watch)
                return
            case .failure(let reason):
                guard reason.allowsStartRetry, anchor.insertionPoint != nil else { return }
            }
        }
    }

    private func install(_ session: CorrectionWatchSession, watch: UInt64) {
        stop()
        self.session = session
        sessionGeneration = watch
        polling = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                if Task.isCancelled { break }
                poll(watch)
            }
        }
    }

    private func stop() {
        session?.cancel()
        session = nil
        sessionGeneration = nil
        polling?.cancel()
        polling = nil
    }

    private func poll(_ watch: UInt64) {
        guard sessionGeneration == watch else { return }
        guard generation.isCurrent(watch), let session else {
            stop()
            return
        }
        let delivery: (edit: CorrectionEdit, isLast: Bool)?
        var abandon = false
        switch session.poll(now: Self.uptime()) {
        case .watching: return
        case .settled(let edit): delivery = (edit, false)
        case .finalize(let edit): delivery = (edit, true)
        case .discard(let reason):
            delivery = nil
            // A cancel comes from the app, which has already stopped everything.
            abandon = reason.forbidsCapturedText && reason != .cancelled
        }
        if delivery?.isLast != false { stop() }
        let generation = self.generation
        if abandon {
            // Stale at once, here, so no result for this watch is used even if it reaches the main actor before the
            // call below.
            guard let abandoned = generation.advance(from: watch) else { return }
            let onAbandon = self.onAbandon
            Task { @MainActor in
                guard generation.isCurrent(abandoned) else { return }
                onAbandon()
            }
        } else if let delivery {
            let onEdit = self.onEdit
            Task { @MainActor in
                guard generation.isCurrent(watch) else { return }
                onEdit(delivery.edit, delivery.isLast, watch)
            }
        }
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

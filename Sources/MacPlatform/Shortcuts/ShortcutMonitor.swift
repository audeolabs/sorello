import Carbon.HIToolbox
import DictationCore
import Foundation
import Observation

/// The global shortcuts (ARCHITECTURE.md, section 6, "Shortcuts"). It owns the one keyboard event tap, feeds what
/// the tap reads to a `ShortcutMatcher`, and delivers the matcher's triggers to its handler, consuming Escape only
/// when the handler says it cancelled something. It also delivers `systemInterrupted` when the screen locks, the
/// user is switched away or the Mac is about to sleep; that comes from system notifications, so it arrives
/// whether or not the tap exists, is paused, or is recording a binding.
///
/// Its status is observable, for the menu and Settings. Without Accessibility there is no tap and no shortcut
/// works: `start()` reports `needsAccessibility` without ever prompting, and should be called again once
/// Accessibility has been granted.
@MainActor
@Observable
public final class ShortcutMonitor {
    public enum Status: Sendable, Equatable {
        /// Not started, or stopped.
        case stopped
        case running
        /// The tap could not be created because Sorello is not trusted for Accessibility.
        case needsAccessibility
        /// Another app has turned on secure input (a password field, for example), so the system sends no keys to
        /// the tap until it is turned off.
        case pausedBySecureInput
    }

    public private(set) var status: Status = .stopped
    public private(set) var bindings: [ShortcutAction: ShortcutBinding]
    /// Whether a binding is being recorded for Settings.
    public private(set) var isRecording = false

    /// Receives the triggers. Held weakly: the monitor never keeps the session alive.
    @ObservationIgnored public weak var handler: (any TriggerHandling)?

    /// How often secure input is checked while a hold is in progress, and otherwise.
    static let holdPollInterval: TimeInterval = 0.25
    static let idlePollInterval: TimeInterval = 1

    @ObservationIgnored private var matcher: ShortcutMatcher
    @ObservationIgnored private var physicalModifiers: Set<ModifierKey> = []
    @ObservationIgnored private let tap: any KeyEventTapping
    @ObservationIgnored private let interruptions: any SystemInterruptionObserving
    @ObservationIgnored private let isSecureInputEnabled: @MainActor () -> Bool
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var recording: CheckedContinuation<ShortcutBinding?, Never>?

    /// A monitor over the real event tap and system notifications. Triggers are stamped with `clock`'s time when
    /// each event arrives; the system clock is the keyboard's own timeline.
    public convenience init(bindings: [ShortcutAction: ShortcutBinding], clock: any SessionClock = SystemSessionClock()) {
        self.init(bindings: bindings, clock: clock, tap: SessionEventTap(), interruptions: WorkspaceInterruptions(),
                  isSecureInputEnabled: { IsSecureEventInputEnabled() })
    }

    init(bindings: [ShortcutAction: ShortcutBinding], clock: any SessionClock, tap: any KeyEventTapping,
         interruptions: any SystemInterruptionObserving, isSecureInputEnabled: @escaping @MainActor () -> Bool) {
        self.bindings = bindings
        self.matcher = ShortcutMatcher(bindings: bindings)
        self.clock = clock
        self.tap = tap
        self.interruptions = interruptions
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    /// Starts observing system interruptions and tries to create the tap. Safe to call again: with the tap
    /// already running it does nothing, and after `needsAccessibility` it tries again.
    public func start() {
        if !observing {
            observing = true
            interruptions.start { [weak self] in self?.deliver(.systemInterrupted) }
        }
        guard !tapInstalled else { return }
        tapInstalled = tap.install { [weak self] message in self?.receive(message) ?? false }
        guard tapInstalled else {
            status = .needsAccessibility
            return
        }
        status = isSecureInputEnabled() ? .pausedBySecureInput : .running
        startPolling()
    }

    /// Removes the tap and stops observing. A hold in progress ends as `holdReleased(.interrupted)` and a
    /// recording ends without a binding.
    public func stop() {
        poll?.cancel()
        poll = nil
        if tapInstalled {
            tap.remove()
            tapInstalled = false
        }
        if observing {
            interruptions.stop()
            observing = false
        }
        interruptMatcher()
        status = .stopped
    }

    /// Replaces the bindings. A hold in progress whose binding changed ends as `holdReleased(.interrupted)`.
    public func setBindings(_ new: [ShortcutAction: ShortcutBinding]) {
        bindings = new
        for trigger in matcher.setBindings(new) { deliver(trigger) }
    }

    /// Captures the next binding from the keyboard for Settings: a key with the modifiers held with it, or a set
    /// of modifier keys pressed and then released. The keys pressed are consumed and no shortcut triggers until it
    /// ends (`systemInterrupted` still arrives). Returns nil if Escape is pressed, the recording is cancelled or
    /// interrupted, the calling task is cancelled, or the tap is not running. A recording already in progress ends
    /// with nil first. The binding is not validated: ask `ShortcutValidation` before saving it.
    public func recordBinding() async -> ShortcutBinding? {
        guard status == .running else { return nil }
        finishRecording(nil)
        for trigger in matcher.startRecording() { deliver(trigger) }
        isRecording = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    matcher.cancelRecording()
                    isRecording = false
                    continuation.resume(returning: nil)
                } else {
                    recording = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRecording() }
        }
    }

    /// Ends a recording in progress without a binding.
    public func cancelRecording() {
        guard matcher.isRecording || recording != nil else { return }
        matcher.cancelRecording()
        finishRecording(nil)
    }

    // MARK: - The tap

    /// Handles one message from the tap and returns whether to swallow the event.
    private func receive(_ message: TapMessage) -> Bool {
        switch message {
        case .disabled:
            Diagnostics.record("shortcuts.tapDisabled")
            tap.reenable()
            interruptMatcher()
            return false
        case .key(let raw):
            guard raw.sourceUserData != SyntheticEvents.tag else { return false }
            guard let event = KeyEvent(type: raw.type, keyCode: raw.keyCode, flags: raw.flags,
                                       isRepeat: raw.isRepeat, time: clock.now, previous: physicalModifiers)
            else { return false }
            physicalModifiers = event.modifiers
            let wasHolding = matcher.isHolding
            let response = matcher.handle(event) { [weak self] trigger in
                self?.handler?.handle(trigger, at: event.time) ?? false
            }
            if let result = response.recording {
                switch result {
                case .recorded(let binding): finishRecording(binding)
                case .cancelled: finishRecording(nil)
                }
            }
            if matcher.isHolding, !wasHolding { startPolling() }
            return response.consume
        }
    }

    // MARK: - Secure input

    /// Reads secure input now. When it has just come on, shortcuts pause, a hold ends as interrupted and a
    /// recording is cancelled; when it has gone off, they run again.
    func checkSecureInput() {
        guard tapInstalled else { return }
        let secure = isSecureInputEnabled()
        switch (status, secure) {
        case (.running, true):
            status = .pausedBySecureInput
            interruptMatcher()
        case (.pausedBySecureInput, false):
            status = .running
        default:
            break
        }
    }

    /// Checks secure input every second, and four times a second while a hold is in progress, so a hold never
    /// outlives the keyboard being taken away.
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self, clock] in
            while !Task.isCancelled {
                let interval = self?.matcher.isHolding == true ? Self.holdPollInterval : Self.idlePollInterval
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.checkSecureInput()
            }
        }
    }

    // MARK: - Delivery

    private func deliver(_ trigger: TriggerEvent) {
        handler?.handle(trigger, at: clock.now)
    }

    private func interruptMatcher() {
        let wasRecording = matcher.isRecording
        physicalModifiers = []
        for trigger in matcher.interrupt() { deliver(trigger) }
        if wasRecording || recording != nil { finishRecording(nil) }
    }

    private func finishRecording(_ binding: ShortcutBinding?) {
        isRecording = false
        let continuation = recording
        recording = nil
        continuation?.resume(returning: binding)
    }
}

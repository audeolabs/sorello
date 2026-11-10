import AppKit
import ApplicationServices
import DictationCore

/// Whether Sorello is trusted for Accessibility, which the shortcuts and the paste need. Trust is granted by the
/// user in System Settings (with the drag card, `PermissionPanel.Controller`); nothing here ever prompts.
public struct AccessibilityPermission: Sendable {
    /// How often `changes()` reads the trust while someone is listening. The system posts no notice of it.
    public static let pollInterval: TimeInterval = 1

    private let clock: any SessionClock
    private let trusted: @Sendable () -> Bool

    public init(clock: any SessionClock = SystemSessionClock()) {
        self.init(clock: clock, isTrusted: { AXIsProcessTrusted() })
    }

    init(clock: any SessionClock, isTrusted: @escaping @Sendable () -> Bool) {
        self.clock = clock
        trusted = isTrusted
    }

    /// Whether the process is trusted now.
    public var isTrusted: Bool { trusted() }

    /// The trust now, then each time it changes. It is read only while the stream is being consumed, and reading
    /// stops when the consumer stops iterating.
    public func changes() -> AsyncStream<Bool> {
        let (clock, trusted) = (clock, trusted)
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last = trusted()
            continuation.yield(last)
            while true {
                do { try await clock.sleep(for: Self.pollInterval) } catch { break }
                let now = trusted()
                if now != last {
                    last = now
                    continuation.yield(now)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Opens the Accessibility pane of System Settings.
    @MainActor
    public func openSettings() {
        PrivacyPermission.accessibility.openSettings()
    }

    /// Shows this copy of the app in Finder, for adding it to the list by hand after a stale entry was removed.
    @MainActor
    public func revealAppInFinder(_ appURL: URL = Bundle.main.bundleURL) {
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}

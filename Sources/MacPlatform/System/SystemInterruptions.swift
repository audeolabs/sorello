import AppKit

/// Tells its owner when this user's session stops being the one in front: the screen locks, another user is
/// switched to, or the Mac is about to sleep. `ShortcutMonitor` turns each into `systemInterrupted`, whatever its
/// tap is doing, so the source is separate from the tap and can be faked in tests.
@MainActor
protocol SystemInterruptionObserving: AnyObject {
    /// Starts observing. `interrupted` is called on the main actor each time. Calling it again replaces the
    /// handler.
    func start(_ interrupted: @escaping @MainActor () -> Void)
    func stop()
}

/// The system's notifications for the three situations: `NSWorkspace.sessionDidResignActiveNotification` (fast
/// user switching), `NSWorkspace.willSleepNotification`, and the distributed `com.apple.screenIsLocked`, which
/// the system posts when the screen locks and which has no constant in the SDK.
@MainActor
final class WorkspaceInterruptions: SystemInterruptionObserving {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")

    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    func start(_ interrupted: @escaping @MainActor () -> Void) {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (workspace, NSWorkspace.willSleepNotification),
            (distributed, Self.screenLocked),
        ]
        for (center, name) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { interrupted() }
            }
            tokens.append((center, token))
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }
}

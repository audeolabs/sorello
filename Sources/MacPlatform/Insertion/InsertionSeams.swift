import AppKit
import CoreGraphics
import Synchronization

/// Whether keys may be posted into this user's session at all. A seam so tests can lock the screen.
public protocol UserSessionReading: Sendable {
    /// True when this user's session is the active one on the console, the screen is not locked and the Mac is not
    /// going to sleep. A paste posted otherwise would go nowhere the user can see, or into the lock screen.
    func isAvailable() -> Bool
}

/// Which app is in front, as a process. A seam so tests can switch apps.
public protocol FrontmostProcessReading: Sendable {
    /// The process identifier of the app in front, or nil when there is none.
    @MainActor func frontmostProcessID() -> Int32?
}

/// The app in front, as `NSWorkspace` reports it.
public struct SystemFrontmostProcess: FrontmostProcessReading {
    /// A reader with no state of its own.
    public init() {}

    @MainActor
    public func frontmostProcessID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// The session's state from the window server, plus whether the Mac has said it is going to sleep. It listens for
/// sleep and wake from the moment it is made until it is released.
public final class SystemUserSession: UserSessionReading {
    /// The window server's key for "the screen is locked". Not declared in the SDK, but it is the key the session
    /// dictionary carries.
    private static let screenLockedKey = "CGSSessionScreenIsLocked"
    /// The value of `kCGSessionOnConsoleKey`, which the SDK declares only as a C macro.
    private static let onConsoleKey = "kCGSSessionOnConsoleKey"

    /// Set between the system's will-sleep and did-wake notifications.
    private final class SleepFlag: Sendable {
        let isSet = Mutex(false)
    }

    private let goingToSleep = SleepFlag()
    private let center: NotificationCenter
    private let observers: Mutex<[any NSObjectProtocol]>

    /// Starts listening for sleep and wake. Made on the main thread, where the workspace lives.
    @MainActor
    public init() {
        center = NSWorkspace.shared.notificationCenter
        let goingToSleep = goingToSleep
        observers = Mutex([
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                goingToSleep.isSet.withLock { $0 = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                goingToSleep.isSet.withLock { $0 = false }
            },
        ])
    }

    deinit {
        let center = center
        observers.withLock { observers in
            for observer in observers { center.removeObserver(observer) }
        }
    }

    public func isAvailable() -> Bool {
        guard !goingToSleep.isSet.withLock({ $0 }),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = session[Self.onConsoleKey] as? Bool ?? false
        let locked = session[Self.screenLockedKey] as? Bool ?? false
        return onConsole && !locked
    }
}

import DesignCore
import DictationCore
import Foundation
import SorelloUI

// The small objects that sit between the session and the rest of the app.

/// Hands each shortcut trigger to the session, and lets the correction coordinator see it first. The monitor holds
/// its handler weakly, so the composition owns this. It decides nothing and calls nothing back into the monitor: it is
/// called from inside the event tap, and so is `SessionRuntime.handle`, which only reduces and returns.
@MainActor
final class TriggerRelay: TriggerHandling {
    private weak var runtime: SessionRuntime?
    /// Sees each trigger before the session does.
    var observer: (@MainActor (TriggerEvent) -> Void)?
    /// Whether a Hold to Talk key is down: a shortcut session is under way, so no suggestion may appear.
    private(set) var holdIsDown = false

    init(runtime: SessionRuntime) {
        self.runtime = runtime
    }

    @discardableResult
    func handle(_ trigger: TriggerEvent, at time: TimeInterval) -> Bool {
        switch trigger {
        case .holdPressed: holdIsDown = true
        case .holdReleased, .holdAbandoned: holdIsDown = false
        default: break
        }
        observer?(trigger)
        return runtime?.handle(trigger, at: time) ?? false
    }
}

/// The app in front, read by the session once, as each dictation starts (`SessionEffect.startCapture`). The reading
/// is also told to `onRead`, which is how the app learns that a dictation started and where it is going: the
/// correction coordinator needs both, and the session reports neither until the dictation ends.
@MainActor
final class NotingFrontmostApp: FrontmostAppReading {
    private let reader: any FrontmostAppReading
    var onRead: (@MainActor (AppIdentity?) -> Void)?

    init(_ reader: any FrontmostAppReading) {
        self.reader = reader
    }

    func frontmostApp() -> AppIdentity? {
        let app = reader.frontmostApp()
        onRead?(app)
        return app
    }
}

/// Where the pill is drawn. The real one is `PillOverlayController`; tests record what it was shown.
@MainActor
protocol PillPresenting: AnyObject {
    var onStop: () -> Void { get set }
    var onCancel: () -> Void { get set }
    var onNoticeAction: (_ notice: UInt64, _ action: String) -> Void { get set }
    var adjustments: PillAdjustments { get set }
    func show(_ display: PillDisplay)
}

extension PillOverlayController: PillPresenting {}

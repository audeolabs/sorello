import AppKit
import QuartzCore

// What Sorello takes from AppKit that macOS 13 does not have (ARCHITECTURE.md, section 15), as SystemCompat does for
// the system's other parts: Apple's own type in the usual build, a stand-in with the same calls in the build for
// older Macs.

#if SORELLO_LEGACY
/// A view's display link: `CADisplayLink`, which a view can make from macOS 14. Before that this is a timer at the
/// highest rate asked for, so the frames are evenly spaced but not tied to the display's refresh. From macOS 14 it
/// passes the view's own display link on.
///
/// It has the calls Sorello makes on a display link and nothing else. Like `CADisplayLink` it keeps its target until
/// it is invalidated.
@MainActor
public final class FrameLink: NSObject {
    public var preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    /// When the frame being prepared will be shown, on `CACurrentMediaTime`'s timeline.
    public private(set) var targetTimestamp: CFTimeInterval = 0

    private weak var view: NSView?
    private var target: AnyObject?
    private let selector: Selector
    private var system: NSObject?
    private var timer: Timer?
    private let usesTimer: Bool

    /// `usesTimer` takes the timer on any system, so a test can run what macOS 13 runs.
    init(view: NSView, target: Any, selector: Selector, usesTimer: Bool = false) {
        self.view = view
        self.target = target as AnyObject
        self.selector = selector
        self.usesTimer = usesTimer
    }

    public func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        if !usesTimer, #available(macOS 14, *), let view {
            let link = view.displayLink(target: self, selector: #selector(systemFrame(_:)))
            link.preferredFrameRateRange = preferredFrameRateRange
            link.add(to: runLoop, forMode: mode)
            system = link
        } else {
            let interval = 1 / TimeInterval(max(preferredFrameRateRange.maximum, 1))
            let timer = Timer(timeInterval: interval, target: self, selector: #selector(timerFrame(_:)), userInfo: nil,
                              repeats: true)
            runLoop.add(timer, forMode: mode)
            self.timer = timer
        }
    }

    public func invalidate() {
        if #available(macOS 14, *) { (system as? CADisplayLink)?.invalidate() }
        system = nil
        timer?.invalidate()
        timer = nil
        target = nil
    }

    @available(macOS 14, *)
    @objc private func systemFrame(_ link: CADisplayLink) {
        targetTimestamp = link.targetTimestamp
        frame()
    }

    @objc private func timerFrame(_ timer: Timer) {
        targetTimestamp = CACurrentMediaTime() + timer.timeInterval
        frame()
    }

    private func frame() {
        _ = target?.perform(selector, with: self)
    }
}

extension NSView {
    /// A display link for this view that calls `selector` on `target` with the link, for each frame.
    public func makeFrameLink(target: Any, selector: Selector) -> FrameLink {
        FrameLink(view: self, target: target, selector: selector)
    }
}
#else
public typealias FrameLink = CADisplayLink

extension NSView {
    /// A display link for this view that calls `selector` on `target` with the link, for each frame.
    public func makeFrameLink(target: Any, selector: Selector) -> FrameLink {
        displayLink(target: target, selector: selector)
    }
}
#endif

#if SORELLO_LEGACY
import AppKit
import QuartzCore
import Testing
@testable import MacCompat

/// What the pill and the drag card rely on from a frame link (ARCHITECTURE.md, section 15), held here for the
/// stand-in's timer, which is what macOS 13 runs: once added to a run loop it calls its target with itself for each
/// frame, with the time the frame will be shown, until it is invalidated. The usual build's frame link is
/// `CADisplayLink` itself, which calls nothing in a process that shows no window, so there is nothing to hold it to
/// here.
@MainActor
@Suite struct FrameLinkTests {
    @MainActor
    private final class Counter: NSObject {
        var frames = 0
        var times: [CFTimeInterval] = []
        var stopAfter = Int.max

        @objc func frame(_ link: FrameLink) {
            frames += 1
            times.append(link.targetTimestamp)
            if frames >= stopAfter { link.invalidate() }
        }
    }

    private func link(to counter: Counter, rate: Float = 60) -> FrameLink {
        let link = FrameLink(view: NSView(), target: counter, selector: #selector(Counter.frame(_:)), usesTimer: true)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 30), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        return link
    }

    private func run(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @Test("A frame link calls its target for each frame, with times that move forward on the media clock")
    func framesArrive() {
        let counter = Counter()
        let start = CACurrentMediaTime()
        let link = link(to: counter)
        run(for: 0.5)
        link.invalidate()
        #expect(counter.frames >= 5, "About 30 frames in half a second; a busy Mac gives fewer")
        #expect(counter.times == counter.times.sorted())
        #expect(counter.times.allSatisfy { $0 >= start && $0 < start + 2 })
    }

    @Test("It keeps to the rate asked for")
    func theRateIsKept() {
        let counter = Counter()
        let link = link(to: counter, rate: 15)
        run(for: 0.5)
        link.invalidate()
        #expect(counter.frames <= 9, "At most 15 frames a second")
    }

    @Test("An invalidated frame link calls nothing more, even when invalidated from its own frame")
    func invalidationStopsIt() {
        let counter = Counter()
        counter.stopAfter = 2
        _ = link(to: counter)
        run(for: 0.4)
        #expect(counter.frames == 2)
        run(for: 0.2)
        #expect(counter.frames == 2)
    }
}
#endif

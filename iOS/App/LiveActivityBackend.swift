import ActivityKit
import Foundation

/// ActivityKit for `SessionActivityDriver` (HostCore), which makes every decision (ARCHITECTURE.md, "Live Activity").
/// Updates carry no alert, so they never sound or wake the screen, but the one the driver asks for (ARCHITECTURE.md,
/// "Live Activity", Alert). ActivityKit's calls are asynchronous; they run one after another, in the order the driver
/// made them, and each acts on the activity as it is when its turn comes.
@MainActor
final class LiveActivityBackend: SessionActivityBackend {
    private var activity: Activity<SessionActivityAttributes>?
    private var queue: Task<Void, Never>?
    /// Calls queued and not yet finished.
    private var pending = 0
    var onRemoved: (@MainActor () -> Void)?
    /// Counts the driver's starts and ends, as they are asked for, not as their queued calls run. An activity reports
    /// its removal only while the count is still the one its start was asked under: once the driver has asked to end
    /// it, or started another, it is on its way out and never reports.
    private var epoch = 0

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func endLeftovers() {
        // Taken now, so an activity this run starts later is never among them.
        let leftovers = Activity<SessionActivityAttributes>.activities
        guard !leftovers.isEmpty else { return }
        enqueue {
            for leftover in leftovers { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// With nothing queued, the request is made now and its refusal reported. Behind an end still in flight (a leftover
    /// at launch, the previous session's) it waits its turn, so the ended activity no longer counts against the
    /// system's limit; a refusal then only leaves the session without an activity.
    func start(_ content: SessionActivityContent) -> Bool {
        epoch += 1
        let epoch = epoch
        guard pending > 0 else { return request(content, epoch) }
        enqueue { [weak self] in _ = self?.request(content, epoch) }
        return true
    }

    func update(_ content: SessionActivityContent, alert: SessionActivityAlert?) {
        let configuration = alert.map {
            AlertConfiguration(title: "\($0.title)", body: "\($0.body)", sound: .default)
        }
        enqueue { [weak self] in await self?.activity?.update(Self.content(content), alertConfiguration: configuration) }
    }

    func end() {
        epoch += 1
        enqueue { [weak self] in
            guard let self, let activity = self.activity else { return }
            self.activity = nil
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func settle() async -> Bool {
        while let queue {
            await queue.value
            if pending == 0 { break }
        }
        return activity != nil
    }

    private func request(_ content: SessionActivityContent, _ epoch: Int) -> Bool {
        do {
            let activity = try Activity.request(attributes: SessionActivityAttributes(), content: Self.content(content))
            self.activity = activity
            watch(activity, epoch)
            return true
        } catch {
            return false
        }
    }

    /// Reports an activity that ends or is dismissed while the driver still counts it as shown: the user removed it
    /// from the Lock Screen, or the system ended it. One the driver has since asked to end, or replaced, is not
    /// reported, whether its queued end has run yet or not (`epoch`).
    private func watch(_ activity: Activity<SessionActivityAttributes>, _ epoch: Int) {
        Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, self.epoch == epoch else { return }
                self.epoch += 1
                if self.activity?.id == activity.id { self.activity = nil }
                self.onRemoved?()
                return
            }
        }
    }

    private static func content(_ content: SessionActivityContent) -> ActivityContent<SessionActivityState> {
        ActivityContent(state: content.state, staleDate: content.staleDate)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        pending += 1
        queue = Task { @MainActor in
            await previous?.value
            await work()
            self.pending -= 1
        }
    }
}

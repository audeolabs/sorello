import Observation

/// Runs `apply` now, and again after each change to anything observable it read, until `stop` is called. This is how
/// the composition keeps every window model, the pill and the shortcut monitor current with the stores and the
/// session: each loop reads its sources and writes its target, and never reads the target, so it cannot feed itself.
///
/// A change is applied on the next turn of the main actor, so several changes made together are applied once.
@MainActor
final class Following {
    private var stopped = false
    private let apply: @MainActor () -> Void

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        run()
    }

    /// No more updates after this.
    func stop() { stopped = true }

    private func run() {
        guard !stopped else { return }
        withObservationTracking(apply) { [weak self] in
            Task { @MainActor [weak self] in self?.run() }
        }
    }
}

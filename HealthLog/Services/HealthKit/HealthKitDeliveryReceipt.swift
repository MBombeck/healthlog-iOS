import Foundation

/// **V1 (1.2)** — HealthKit's observer completion handler, delivered exactly once.
///
/// A background delivery keeps the process alive only until the app calls the
/// handler `HKObserverQuery` passes in. Until 1.1.1 the handler was called the
/// moment the change was noted, before the drain had read a page or the
/// statistics sweep had posted, so iOS was free to suspend the process with the
/// day totals unsent. Now it fires when the delivery's work is done, or at
/// ``deadline``, whichever comes first; a late second call is a no-op. Same
/// one-shot shape as `OneShotCompletion` for the `BGTask` completion.
///
/// `@unchecked Sendable` with `NSLock`: the handler HealthKit hands over is a
/// plain closure, and the lock is what proves it runs once.
final class HealthKitDeliveryReceipt: @unchecked Sendable {
    /// How long a delivery may hold HealthKit's receipt. Inside the runtime iOS
    /// grants a background delivery, and long enough for one statistics sweep
    /// and one bucket request on a slow network.
    static let deadline: Duration = .seconds(20)

    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var timer: Task<Void, Never>?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Calls the handler unless it was already called.
    func fire() {
        let (pending, timer) = lock.withLock { () -> ((() -> Void)?, Task<Void, Never>?) in
            defer {
                handler = nil
                self.timer = nil
            }
            return (handler, self.timer)
        }
        timer?.cancel()
        pending?()
    }

    /// Fires on its own after `deadline` if the work has not finished by then.
    func arm(deadline: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let task = Task { [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            self?.fire()
        }
        let keep = lock.withLock { () -> Bool in
            guard handler != nil else { return false }
            timer = task
            return true
        }
        if !keep { task.cancel() }
    }

    var hasFired: Bool {
        lock.withLock { handler == nil }
    }
}

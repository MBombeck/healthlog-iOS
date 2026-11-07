import Foundation

/// **SYNC-HR (1.5, #159 / HealthLog#1326) — waiting for work that may
/// never finish, but never forever.**
///
/// `await task.value` on an unstructured task cannot be cancelled and has no
/// deadline. That was the shape of the pulse stall: a sweep whose HealthKit
/// answer never came kept every later caller waiting on it until the app was
/// restarted. This waits for a task at most `limit`, stops early when
/// `isExpired` turns true or the caller is cancelled, and says which of the
/// four happened. It never cancels `task` itself; whether the work is
/// abandoned is the owner's decision.
///
/// A task that never finishes keeps one small helper task parked on it. That
/// is the price of not being able to cancel `Task.value`; every owner here
/// also cancels or fences the work it gave up on.
enum BoundedWait {
    enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        case timedOut
        case expired
        case cancelled
    }

    /// How often `isExpired` is asked while waiting.
    static let defaultPoll: Duration = .milliseconds(250)

    static func value<Value: Sendable>(
        of task: Task<Value, Never>,
        limit: Duration,
        poll: Duration = BoundedWait.defaultPoll,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> Outcome<Value> {
        if isExpired() { return .expired }
        let answer = OneShotAnswer<Outcome<Value>>()
        let waiter = Task { await answer.resolve(.finished(task.value)) }
        let watch = Task {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while !Task.isCancelled {
                if isExpired() { return answer.resolve(.expired) }
                let now = ContinuousClock.now
                if now >= deadline { return answer.resolve(.timedOut) }
                try? await Task.sleep(for: min(poll, now.duration(to: deadline)))
            }
        }
        let outcome = await withTaskCancellationHandler {
            await answer.value()
        } onCancel: {
            answer.resolve(.cancelled)
        }
        waiter.cancel()
        watch.cancel()
        return outcome
    }
}

/// A value that is set at most once and can be awaited by one caller. The
/// first `resolve` wins; later ones are ignored.
final class OneShotAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        lock.lock()
        guard resolved == nil else {
            lock.unlock()
            return
        }
        resolved = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolved {
                lock.unlock()
                continuation.resume(returning: resolved)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

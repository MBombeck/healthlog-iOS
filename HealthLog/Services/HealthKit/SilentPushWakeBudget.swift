import Foundation

/// The time a silent push may take before the app answers iOS.
///
/// iOS gives a `content-available` wake about 30 seconds. A process still
/// working after that is killed, and the system then delivers later pushes
/// less often. The work gets ``limit`` and is told when it is up: its
/// expiry check turns true and its task is cancelled, which holds every
/// cursor mid-flight. The answer always comes before the system's own end.
enum SilentPushWakeBudget {
    /// Under the roughly 30 seconds iOS grants, with room for the answer.
    static let limit: Duration = .seconds(25)

    /// Runs `work` for at most `limit`. Returns its value, or `fallback`
    /// when the time ran out first.
    static func run<Value: Sendable>(
        limit: Duration = SilentPushWakeBudget.limit,
        fallback: Value,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        work: @escaping @Sendable (_ isExpired: @escaping @Sendable () -> Bool) async -> Value
    ) async -> Value {
        let expiry = ExpiryFlag()
        let answer = OneShotAnswer<Value>()
        let worker = Task {
            let value = await work { expiry.isSet }
            answer.resolve(value)
        }
        let timer = Task {
            do {
                try await sleep(limit)
            } catch {
                return
            }
            // Decide first, then cancel: a worker woken by the cancel must not
            // be able to answer ahead of the fallback.
            expiry.set()
            answer.resolve(fallback)
            worker.cancel()
        }
        let value = await answer.value()
        timer.cancel()
        return value
    }

    /// Set once when the budget is spent; read from any task.
    final class ExpiryFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        var isSet: Bool {
            lock.withLock { expired }
        }

        func set() {
            lock.withLock { expired = true }
        }
    }
}

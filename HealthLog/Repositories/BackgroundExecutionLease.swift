import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Build 274 (public #4) — a lease on background execution time around a write
/// to the outbox store in the shared app-group container.
///
/// Build 271 was terminated by RunningBoard with `0xdead10cc` ("holding a file
/// lock or sqlite database lock while suspended"): a HealthKit observer wake
/// persisted a retry row while the process was being suspended. iOS grants
/// time for exactly this through a background-task assertion; without one the
/// suspension can land inside the SQLite transaction. The lease is taken
/// BEFORE the write and released after it; when the system refuses to grant
/// time the body is not run and `nil` says so.
public protocol BackgroundExecutionLeasing: Sendable {
    /// Runs `body` under a background-task assertion named `name`.
    /// - Returns: the body's value, or `nil` WITHOUT running the body when no
    ///   time was granted. The caller treats `nil` as "not persisted" — never
    ///   as something to retry inside the same wake.
    func withLease<T: Sendable>(
        named name: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T?
}

/// Build 274 (public #4) — always grants: tests, and builds without a UIKit
/// application object. Keeps every existing call path writing exactly as before.
public struct UnconditionalBackgroundExecutionLease: BackgroundExecutionLeasing {
    /// Build 274 (public #4) — public so the queue's public initializers can
    /// name it as their default lease.
    public init() {}

    /// Build 274 (public #4) — runs the body unconditionally and never returns
    /// `nil`, so no caller can mistake this lease for a refusal.
    public func withLease<T: Sendable>(
        named _: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await body()
    }
}

#if canImport(UIKit)
    /// Build 274 (public #4) — the production lease:
    /// `UIApplication.beginBackgroundTask(withName:)` around the body.
    /// Expiration cancels the body's task; the assertion is always ended, on
    /// success, on throw and on expiry.
    ///
    /// Unavailable to app extensions: `HealthLog/Repositories` is compiled into
    /// the `HealthLogWidgets` extension as well, and `UIApplication.shared` is
    /// forbidden there. The extension's own process lifetime is held by its
    /// host, so it keeps the unconditional lease; only the app process — where
    /// the HealthKit observer wake that killed build 271 runs — takes an
    /// assertion. Marking the type (rather than excluding the file) keeps the
    /// extension building while the app still gets the real lease.
    @available(iOSApplicationExtension, unavailable)
    struct UIKitBackgroundExecutionLease: BackgroundExecutionLeasing {
        /// Build 274 (public #4) — bridges the expiration handler (fires once,
        /// on the main thread, at an unknown moment) to the body's task, which
        /// is created only after the lease exists, and owns the one-shot latch
        /// that decides WHO ends the assertion.
        ///
        /// Internal rather than private so `BackgroundExecutionLeaseExpiryTests`
        /// can pin the bridge directly: the production lease needs a real
        /// `UIApplication` and is therefore unreachable from a unit test, but
        /// this is the part with the races worth pinning.
        ///
        /// One lock, three fields, no re-entrancy: every mutation happens under
        /// `lock.withLock`, and the cancel closure is invoked OUTSIDE the lock so
        /// a cancellation handler can never deadlock against the expiry.
        final class Expiry: @unchecked Sendable {
            private let lock = NSLock()
            private var cancel: (@Sendable () -> Void)?
            private var expired = false
            private var ended = false

            /// Build 274 (public #4) — attaches the body's cancellation; fires
            /// it immediately when expiry already happened before the task ran.
            /// The closure is not retained after an expiry, so the cancel fires
            /// exactly once no matter which side arrives first.
            func attach(_ cancel: @escaping @Sendable () -> Void) {
                let fireNow: Bool = lock.withLock {
                    if expired { return true }
                    self.cancel = cancel
                    return false
                }
                if fireNow { cancel() }
            }

            /// Build 274 (public #4) — records the expiry and cancels the body
            /// if it is already running. A second expiry is a no-op: the handler
            /// is documented to fire once, and firing a stale cancel would tear
            /// down whatever task inherited the reference.
            func expire() {
                let cancel: (@Sendable () -> Void)? = lock.withLock {
                    guard !expired else { return nil }
                    expired = true
                    let pending = self.cancel
                    self.cancel = nil
                    return pending
                }
                cancel?()
            }

            /// Build 274 (public #4) — the one-shot end latch. `true` for the
            /// first caller only; that caller — the expiration handler or the
            /// tail path, whichever gets there first — owns the single
            /// `endBackgroundTask`. A second end would release an assertion this
            /// lease no longer holds.
            func markEnded() -> Bool {
                lock.withLock {
                    guard !ended else { return false }
                    ended = true
                    return true
                }
            }
        }

        /// Build 274 (public #4) — the assertion identifier is only known AFTER
        /// `beginBackgroundTask` returns, yet the expiration handler passed into
        /// that same call has to end it. The box closes the cycle. It is
        /// main-actor isolated (hence `Sendable`) because both writers — the
        /// `MainActor.run` that begins the assertion and the handler, which UIKit
        /// documents as firing on the main thread — are on the main actor, and
        /// the write happens synchronously before the handler can ever run.
        @MainActor
        private final class AssertionIdentifier {
            var value: UIBackgroundTaskIdentifier = .invalid
        }

        /// Build 274 (public #4) — takes the assertion first, runs the body only
        /// when the system granted time, and ends the assertion EXACTLY once, on
        /// whichever path reaches the latch first.
        ///
        /// The end used to sit only on the tail path, after `await work.value`.
        /// That is the one arrangement iOS kills for: cancelling the body's task
        /// is advisory, and `OutboxStore.enqueue` — a SwiftData save — never
        /// checks cancellation, so a write straddling the expiry held the
        /// assertion well past its expiration handler. Ending inside the handler
        /// (on the main actor, where UIKit fires it) hands the assertion back at
        /// the moment the system asks for it; the tail then sees the latch taken
        /// and skips its own end.
        ///
        /// The body's result is still returned as-is. A write that completed
        /// after the expiry is a real write, and reporting it as refused would
        /// make the caller re-enqueue a row that is already on disk.
        func withLease<T: Sendable>(
            named name: String,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T? {
            let expiry = Expiry()
            let identifier = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                let assertion = AssertionIdentifier()
                assertion.value = UIApplication.shared.beginBackgroundTask(withName: name) {
                    // UIKit fires this on the main thread, and `assertion.value`
                    // was written synchronously before this closure could run.
                    MainActor.assumeIsolated {
                        expiry.expire()
                        let identifier = assertion.value
                        guard identifier != .invalid, expiry.markEnded() else { return }
                        UIApplication.shared.endBackgroundTask(identifier)
                    }
                }
                return assertion.value
            }
            guard identifier != .invalid else {
                // No time granted: the write must not start. The name is a fixed
                // literal chosen by the caller, never data.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.info("background lease refused [\(name, privacy: .public)] — write held")
                return nil
            }
            let work = Task { try await body() }
            expiry.attach { work.cancel() }
            let outcome: Result<T, any Error>
            do {
                outcome = try await .success(work.value)
            } catch {
                outcome = .failure(error)
            }
            if expiry.markEnded() {
                await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
            }
            return try outcome.get()
        }
    }
#endif

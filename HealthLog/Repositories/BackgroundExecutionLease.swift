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
        /// is created only after the lease exists.
        private final class Expiry: @unchecked Sendable {
            private let lock = NSLock()
            private var cancel: (@Sendable () -> Void)?
            private var expired = false

            /// Build 274 (public #4) — attaches the body's cancellation; fires
            /// it immediately when expiry already happened before the task ran.
            func attach(_ cancel: @escaping @Sendable () -> Void) {
                let fireNow: Bool = lock.withLock {
                    self.cancel = cancel
                    return expired
                }
                if fireNow { cancel() }
            }

            /// Build 274 (public #4) — records the expiry and cancels the body
            /// if it is already running.
            func expire() {
                let cancel: (@Sendable () -> Void)? = lock.withLock {
                    expired = true
                    return self.cancel
                }
                cancel?()
            }
        }

        /// Build 274 (public #4) — takes the assertion first, runs the body only
        /// when the system granted time, and ends the assertion on every exit.
        func withLease<T: Sendable>(
            named name: String,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T? {
            let expiry = Expiry()
            let identifier = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: name) {
                    expiry.expire()
                }
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
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
            return try outcome.get()
        }
    }
#endif

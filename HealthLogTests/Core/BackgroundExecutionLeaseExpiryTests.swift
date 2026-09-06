import Foundation
@testable import HealthLog
import Testing

#if canImport(UIKit)
    /// Build 274 (public #4) — the production lease's expiry bridge, which had no
    /// coverage at all: `UIKitBackgroundExecutionLease.Expiry` carries the
    /// expiration handler (fires once, on the main thread, at an unknown moment)
    /// over to the body's task, and now also latches the one-shot end of the
    /// background-task assertion. Both halves are exactly the kind of racy
    /// bookkeeping that only a test keeps honest: a cancel fired twice would tear
    /// down an unrelated task, and an assertion ended twice (or never) is the
    /// RunningBoard kill this whole build is about.
    @Suite("Background-execution lease — the expiry bridge")
    struct BackgroundExecutionLeaseExpiryTests {
        /// Build 274 (public #4) — counts cancel invocations across threads; the
        /// expiry bridge is lock-based and `@unchecked Sendable`, so its probe is
        /// too.
        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.withLock { value += 1 }
            }

            /// Named `calls`, not `count`: swiftlint's `empty_count` reads any
            /// `count == 0` as a missed `isEmpty`, and a cancel-invocation tally
            /// is not a collection.
            var calls: Int {
                lock.withLock { value }
            }
        }

        @Test("a cancel attached before the expiry fires exactly once")
        func attachThenExpireFiresOnce() {
            let expiry = UIKitBackgroundExecutionLease.Expiry()
            let counter = Counter()
            expiry.attach { counter.increment() }
            #expect(counter.calls == 0, "attaching alone must not cancel the body")
            expiry.expire()
            #expect(counter.calls == 1)
        }

        @Test("a cancel attached after the expiry fires immediately, exactly once")
        func expireThenAttachFiresImmediatelyOnce() {
            let expiry = UIKitBackgroundExecutionLease.Expiry()
            let counter = Counter()
            expiry.expire()
            expiry.attach { counter.increment() }
            #expect(counter.calls == 1, "the body's task started after the expiry — cancel it at once")
        }

        @Test("a second expiry does not fire the cancel again")
        func doubleExpireFiresOnce() {
            let expiry = UIKitBackgroundExecutionLease.Expiry()
            let counter = Counter()
            expiry.attach { counter.increment() }
            expiry.expire()
            expiry.expire()
            #expect(counter.calls == 1)
        }

        @Test("the ended latch reports true exactly once")
        func markEndedIsOneShot() {
            let expiry = UIKitBackgroundExecutionLease.Expiry()
            #expect(expiry.markEnded(), "the first caller owns endBackgroundTask")
            #expect(!expiry.markEnded(), "a second end would release an assertion this lease no longer holds")
        }

        @Test("the expiration handler's end and the tail path's end cannot both win")
        func expiryEndAndTailEndAreExclusive() {
            let expiry = UIKitBackgroundExecutionLease.Expiry()
            let counter = Counter()
            expiry.attach { counter.increment() }
            expiry.expire()
            // The expiration handler ends the assertion where it fires; the tail
            // path then finds the latch already taken and skips its own end.
            #expect(expiry.markEnded())
            #expect(!expiry.markEnded())
            #expect(counter.calls == 1)
        }
    }
#endif

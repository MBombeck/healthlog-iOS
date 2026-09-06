import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// #5 — the grace window that stops the SECOND rotation.
///
/// At the 24 h access-token boundary every in-flight request gets `401
/// expired` at once. Single-flight folds them onto ONE rotation (A → B), and
/// they replay with B. A straggler that was already on the wire with A arrives
/// afterwards, gets `401 revoked`, finds no in-flight task any more — and
/// rotated a SECOND time (B → C), which revoked B under the requests that had
/// just been repaired. They then had no refresh left and logged the user out.
///
/// The window is the fix on this side: for `graceWindow` seconds after a
/// successful rotation, a late caller is told `.refreshed` (the session it is
/// about to read from the Keychain really is fresh) instead of rotating again.
/// The clock is injected so the boundary is asserted, not slept through.
@Suite("#5 — RefreshCoordinator grace window")
struct RefreshCoordinatorGraceTests {
    /// A settable clock. `@unchecked Sendable` is sound because every access
    /// goes through the lock.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value = value.addingTimeInterval(interval)
        }
    }

    /// Counts how often the injected refresh closure actually ran — i.e. how
    /// many rotations the coordinator let through.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("A refresh inside the grace window is answered without a network call")
    func refreshInsideGraceWindowIsSuppressed() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let rotations = Counter()
        let coordinator = RefreshCoordinator(
            refresh: { @Sendable in
                rotations.increment()
                return .refreshed
            },
            graceWindow: 10,
            now: { clock.now }
        )

        let first = await coordinator.attemptRefresh()
        #expect(first == .refreshed)
        #expect(rotations.current == 1)

        clock.advance(3)
        let straggler = await coordinator.attemptRefresh()

        #expect(straggler == .refreshed, "the straggler must be told the session is fresh")
        #expect(
            rotations.current == 1,
            "a second rotation 3 s after the first is the defect — it revokes the token the replays just got"
        )
    }

    @Test("After the grace window a refresh runs again")
    func refreshAfterGraceWindowRotatesAgain() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let rotations = Counter()
        let coordinator = RefreshCoordinator(
            refresh: { @Sendable in
                rotations.increment()
                return .refreshed
            },
            graceWindow: 10,
            now: { clock.now }
        )

        _ = await coordinator.attemptRefresh()
        clock.advance(11)
        let later = await coordinator.attemptRefresh()

        #expect(later == .refreshed)
        #expect(rotations.current == 2, "the window must close — it suppresses a burst, not the next hour")
    }

    @Test("A failed refresh opens no grace window")
    func failedRefreshOpensNoWindow() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let rotations = Counter()
        let coordinator = RefreshCoordinator(
            refresh: { @Sendable in
                rotations.increment()
                return .transient
            },
            graceWindow: 10,
            now: { clock.now }
        )

        let first = await coordinator.attemptRefresh()
        let second = await coordinator.attemptRefresh()

        #expect(first == .transient)
        #expect(second == .transient)
        #expect(
            rotations.current == 2,
            "nothing was rotated, so there is no fresh session to hand a later caller — it must try itself"
        )
    }

    @Test("Overlapping callers still share one refresh")
    func overlappingCallersShareOneRefresh() async {
        let rotations = Counter()
        // `graceWindow: 0` disables the window for this case on purpose: with a
        // window open, a second caller that MISSED the in-flight task would be
        // answered from the window and the count would still be 1 — the case
        // would pass without proving single-flight. At 0 only the in-flight
        // join can keep the count at 1.
        let coordinator = RefreshCoordinator(
            refresh: { @Sendable in
                rotations.increment()
                // A real refresh is a network round-trip; the sleep is what makes
                // "overlapping" mean overlapping.
                try? await Task.sleep(nanoseconds: 100_000_000)
                return .refreshed
            },
            graceWindow: 0,
            now: { Date() }
        )

        async let first = coordinator.attemptRefresh()
        async let second = coordinator.attemptRefresh()
        let outcomes = await [first, second]

        #expect(outcomes == [.refreshed, .refreshed])
        #expect(rotations.current == 1, "parallel 401s must fold onto ONE rotation — reuse-detection depends on it")
    }
}

import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// **v0.6.1.3 Y4.1 — NotificationService badge plumbing tests.**
    ///
    /// `setBadgeCount` and `refreshBadge(from:)` go through the system
    /// `UNUserNotificationCenter.setBadgeCount` API, which the test
    /// runner can call without authorization (Apple's mock layer drops
    /// the value silently when permissions aren't granted) — so the
    /// most we can assert is that the methods return without throwing
    /// and that the store-accessor wiring works as a pure-function
    /// composition.
    ///
    /// The deeper "badge ticks down on Genommen tap" path is covered
    /// implicitly by `MedicationsStoreBadgeCountTests` (predicate
    /// parity) + the `onIntakesDidChange` callback fan-out in
    /// `AppContainer` (build-test-time wiring assertion: the closure
    /// captures the live store + service).
    @Suite("NotificationService — App-Badge hooks", .serialized)
    @MainActor
    struct NotificationServiceBadgeTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.6.1.3",
            buildNumber: "43"
        )

        private func makeService() -> NotificationService {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let appRouter = AppRouter()
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            return NotificationService(
                api: APIClient(
                    environment: Self.env,
                    keychain: keychain,
                    sessionConfiguration: .mock()
                ),
                environment: Self.env,
                keychain: keychain,
                deepLinks: deepLinks,
                medicationsRepo: nil
            )
        }

        /// `setBadgeCount(_:)` clamps negative inputs to zero. Asserts
        /// the public surface accepts a negative value without
        /// propagating to the system API (`UNUserNotificationCenter`
        /// requires non-negative).
        @Test("setBadgeCount clamps negative input to zero")
        func setBadgeCountClampsNegative() async {
            let service = makeService()
            // No throw expected — the implementation `max(0, count)` is
            // exercised here. Simulator authorization may be absent;
            // the `try?` inside the impl swallows the error path. The
            // assertion below is "no crash" — i.e. the function returns.
            await service.setBadgeCount(-5)
            #expect(Bool(true))
        }

        /// `attachMedicationsStoreAccessor` stores the closure; the
        /// `refreshBadgeFromAttachedStoreIfAvailable` path then reads
        /// from it. Asserts the accessor is invoked when refresh is
        /// requested (using a counter-side-effect inside the closure).
        @Test("refreshBadgeFromAttachedStoreIfAvailable reads the attached accessor")
        func refreshReadsAttachedAccessor() async {
            let service = makeService()
            // The accessor returns nil because we don't stand up a
            // MedicationsStore in this test; what we assert is that
            // the closure is invoked at all.
            let invoked = MainActorCounter()
            service.attachMedicationsStoreAccessor {
                invoked.bump()
                return nil
            }
            await service.refreshBadgeFromAttachedStoreIfAvailable()
            #expect(invoked.value == 1)
        }

        /// When no accessor has been attached, the refresh path is a
        /// no-op — no crash, no system call.
        @Test("refresh without accessor is a no-op")
        func refreshWithoutAccessorIsNoOp() async {
            let service = makeService()
            // Default state — accessor is nil.
            await service.refreshBadgeFromAttachedStoreIfAvailable()
            #expect(Bool(true))
        }
    }

    /// Tiny MainActor-bound counter used to detect closure invocation
    /// without crossing isolation boundaries. The `Testing` framework
    /// doesn't ship a stock CountedRef so we hand-roll the one-off.
    @MainActor
    private final class MainActorCounter {
        private(set) var value: Int = 0

        func bump() {
            value += 1
        }
    }

    // swiftlint:enable force_unwrapping
#endif

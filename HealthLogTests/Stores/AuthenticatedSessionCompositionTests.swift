import Foundation
@testable import HealthLog
import Testing

@Suite("AuthenticatedSessionCompositionTests")
struct AuthenticatedSessionCompositionTests {
    private enum DeletionFailure: Error {
        case rejected
    }

    private actor ControlledQuiescence {
        private var didEnter = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            didEnter = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    @Test
    func hookInvalidationPrecedesCleanupAndReadmission() async throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let oldLease = try #require(registry.activate(ownerID: "account-a"))
        let quiescence = ControlledQuiescence()
        let hooks = AuthenticatedSessionBoundaryHooks(
            invalidate: {
                registry.invalidate()
            },
            awaitQuiescence: {
                await quiescence.suspend()
            },
            activate: { ownerID in
                registry.activate(ownerID: ownerID)
            }
        )

        let transition = Task {
            hooks.invalidate()
            await hooks.awaitQuiescence()
            hooks.activate("account-b")
        }
        await quiescence.waitUntilEntered()
        await quiescence.release()
        await transition.value

        #expect(
            !oldLease.isCurrent,
            "EXPECTED_RED: admission preceded invalidation and drain"
        )
    }

    @Test
    func failedDeletionDoesNotInvalidateLiveLease() async throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let liveLease = try #require(registry.activate(ownerID: "account-a"))

        do {
            try await failingDeletionAttempt()
            Issue.record("deletion fixture unexpectedly succeeded")
        } catch DeletionFailure.rejected {
            // A failed server deletion never reaches the terminal boundary hook.
        }

        #expect(liveLease.isCurrent)
        #expect(try #require(registry.capture(ownerID: "account-a")).isCurrent)
    }

    private func failingDeletionAttempt() async throws {
        throw DeletionFailure.rejected
    }
}

#if !SWIFT_PACKAGE

    /// Plan 06-05 — the composed boundary hooks must act on the SAME shared
    /// registry the container's stores and `AuthStore` consume, so the terminal
    /// teardown owner can invalidate/readmit through one production surface.
    @MainActor
    extension AuthenticatedSessionCompositionTests {
        @Test
        func boundaryHooksShareTheComposedRegistry() throws {
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
            let hooks = container.authenticatedSessionBoundaryHooks

            hooks.activate("account-a")
            let leaseA = try #require(
                container.authStore.captureAuthenticatedSession(ownerID: "account-a")
            )
            #expect(leaseA.isCurrent)

            hooks.invalidate()
            #expect(!leaseA.isCurrent, "hook invalidation must stale the store-visible lease")
            #expect(container.authStore.captureAuthenticatedSession(ownerID: "account-a") == nil)

            hooks.activate("account-b")
            #expect(!leaseA.isCurrent, "replacement admission must never revive account A's lease")
            #expect(container.authStore.captureAuthenticatedSession(ownerID: "account-b") != nil)
        }

        /// 06-05 Task 4 — `awaitQuiescence` is no longer a stub: it must
        /// cancel AND await the composition's registered owned-task drains
        /// (the measurements retained-task family from 06-03).
        @Test
        func boundaryQuiescenceDrainsComposedOwnedWork() async {
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
            let parked = ParkedAuthenticatedWorkProbe()
            container.measurementsStore.seriesHydrationTask = Task { await parked.run() }
            let hooks = container.authenticatedSessionBoundaryHooks

            hooks.invalidate()
            await hooks.awaitQuiescence()

            #expect(
                parked.isFinished,
                "awaitQuiescence must cancel and await the retained measurement work"
            )
            container.measurementsStore.seriesHydrationTask?.cancel()
            await container.measurementsStore.seriesHydrationTask?.value
        }
    }

#endif // !SWIFT_PACKAGE

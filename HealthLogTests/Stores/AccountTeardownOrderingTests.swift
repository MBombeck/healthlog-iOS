// Plan 06-05 — four-terminal-path teardown ordering matrix.
//
// One awaited teardown orchestrator must own user logout, terminal 401,
// successful deletion, and switch-server: invalidate the shared authenticated
// session lease, cancel and await every owned task (including the measurements
// historical/hydration/mirror work from 06-03), run the reason-specific cleanup
// cascade, and only then publish the terminal state and permit replacement
// admission. A failed deletion must preserve the live lease and run no
// terminal teardown.
//
// The harness drives the PRODUCTION hooks (`onPostLogoutHook`,
// `unauthorizedRef`, `localCleanupHook` → `performFullLocalLogout`,
// `handleLocalLogout`) against the real `AppContainer` composition — never a
// test-local coordinator — and observes lease currency, an owned parked task,
// and the cascade-tail hook. No sleeps: the parked task is cancellation-aware
// and every observation is sequenced by awaited completion.
//
// App-target-only (AppContainer), so skipped in the SPM-library build.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    import Synchronization
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// A cancellation-aware owned producer planted into the production
    /// `MeasurementsStore` retained-task slot. It suspends until the
    /// surrounding task is cancelled — exactly the shape of the 06-03
    /// historical-backfill/hydration work the teardown must cancel AND
    /// await. `isFinished` flips only after the task body has fully
    /// drained, so ordering observations are deterministic without sleeps.
    /// File-scope so `AuthenticatedSessionCompositionTests` can reuse it for
    /// the boundary-hook quiescence proof.
    final class ParkedAuthenticatedWorkProbe: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<Void, Never>?
            var cancelled = false
            var finished = false
        }

        private let state = Mutex(State())

        var isFinished: Bool {
            state.withLock { $0.finished }
        }

        func run() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeImmediately = state.withLock { state -> Bool in
                        if state.cancelled { return true }
                        state.continuation = continuation
                        return false
                    }
                    if resumeImmediately { continuation.resume() }
                }
            } onCancel: {
                let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    state.cancelled = true
                    let parked = state.continuation
                    state.continuation = nil
                    return parked
                }
                continuation?.resume()
            }
            state.withLock { $0.finished = true }
        }
    }

    @MainActor
    @Suite("AccountTeardownOrderingTests", .serialized)
    struct AccountTeardownOrderingTests {
        // MARK: - Harness

        /// Cascade-tail observation — records what the LAST cascade step saw,
        /// so invalidate-before-cleanup and drain-before-cleanup are provable.
        @MainActor
        private final class CascadeTailLog {
            struct Entry {
                let drained: Bool
                let leaseInvalidated: Bool
            }

            private(set) var entries: [Entry] = []

            func record(drained: Bool, leaseInvalidated: Bool) {
                entries.append(Entry(drained: drained, leaseInvalidated: leaseInvalidated))
            }
        }

        /// Thread-safe spy for the `@Sendable` HK-anchor cleanup hook.
        private final class AnchorCleanupSpy: Sendable {
            private struct State: Sendable {
                var count = 0
                var lastOwner: String?
            }

            private let state = Mutex(State())

            func record(owner: String?) {
                state.withLock {
                    $0.count += 1
                    $0.lastOwner = owner
                }
            }

            var count: Int {
                state.withLock { $0.count }
            }

            var lastOwner: String? {
                state.withLock { $0.lastOwner }
            }
        }

        /// Keychain spy for the switch-server coordinator leg: passes every
        /// call through to `base`, but snapshots the drain probe at the exact
        /// moment the persisted server URL is written — proving the server
        /// mutation happened only AFTER the old session's owned work drained.
        private final class ServerSwitchKeychainSpy: KeychainStoring, Sendable {
            private let base: InMemoryKeychain
            private let drainProbe: @Sendable () -> Bool
            private let drainedAtServerURLWrite = Mutex<Bool?>(nil)

            init(base: InMemoryKeychain, drainProbe: @escaping @Sendable () -> Bool) {
                self.base = base
                self.drainProbe = drainProbe
            }

            var drainedWhenServerURLWasWritten: Bool? {
                drainedAtServerURLWrite.withLock { $0 }
            }

            func setString(_ value: String, forKey key: String) throws {
                if key == KeychainKey.serverURL {
                    let drained = drainProbe()
                    drainedAtServerURLWrite.withLock { $0 = drained }
                }
                try base.setString(value, forKey: key)
            }

            func getString(forKey key: String) -> String? {
                base.getString(forKey: key)
            }

            func setData(_ data: Data, forKey key: String) throws {
                try base.setData(data, forKey: key)
            }

            func getData(forKey key: String) -> Data? {
                base.getData(forKey: key)
            }

            func remove(forKey key: String) throws {
                try base.remove(forKey: key)
            }

            func removeAll() throws {
                try base.removeAll()
            }
        }

        private func makeContainer(keychain: KeychainStoring) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }

        /// Real `AuthStore` over a real `AuthService`/`APIClient` (stub
        /// `URLSession`, never a mock server) that SHARES the container's
        /// authenticated-session registry — so the production deletion paths
        /// and the container cascade act on one lease boundary, exactly like
        /// the composed app.
        private func makeDeletionAuthStore(
            container: AppContainer,
            keychain: InMemoryKeychain
        ) throws -> AuthStore {
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
            let auth = AuthService(api: api, keychain: keychain, passkey: TestPasskeyService())
            let suite = "teardown-ordering.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return AuthStore(
                auth: auth,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: container.authenticatedSessionRegistry
            )
        }

        private func user(_ id: String) -> User {
            User(id: id, email: nil, username: nil, displayName: nil, createdAt: .now)
        }

        private func drainPlantedTask(_ container: AppContainer) async {
            container.measurementsStore.seriesHydrationTask?.cancel()
            await container.measurementsStore.seriesHydrationTask?.value
        }

        // MARK: - User logout + terminal 401

        /// User logout and terminal 401 must invalidate account A's shared
        /// lease, cancel-and-await the owned measurement work, and complete the
        /// HK-anchor cleanup for the captured pre-wipe owner BEFORE the
        /// terminal state publishes and a replacement admission can enter.
        @Test
        func terminalPathsInvalidateDrainCleanupBeforeReadmission() async throws {
            // Leg 1 — user-initiated logout through the production hook.
            let logoutKeychain = InMemoryKeychain()
            try logoutKeychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try logoutKeychain.setString("account-a", forKey: KeychainKey.userID)
            let container = makeContainer(keychain: logoutKeychain)
            container.authStore.setPhaseForTesting(.authenticated(user("account-a")))
            let logoutLease = try #require(
                container.authStore.activateAuthenticatedSession(ownerID: "account-a")
            )
            let parkedLogoutWork = ParkedAuthenticatedWorkProbe()
            container.measurementsStore.seriesHydrationTask = Task { await parkedLogoutWork.run() }
            let cascadeTail = CascadeTailLog()
            container.notificationClearOnLogoutHook = { @MainActor in
                cascadeTail.record(
                    drained: parkedLogoutWork.isFinished,
                    leaseInvalidated: !logoutLease.isCurrent
                )
            }

            let postLogoutHook = try #require(container.authStore.onPostLogoutHook)
            await postLogoutHook()

            let logoutOrderingHolds = !logoutLease.isCurrent
                && parkedLogoutWork.isFinished
                && cascadeTail.entries.count == 1
                && cascadeTail.entries.allSatisfy { $0.drained && $0.leaseInvalidated }
            await drainPlantedTask(container)

            // Leg 2 — terminal 401 through the production unauthorized bridge.
            let bridgeKeychain = InMemoryKeychain()
            try bridgeKeychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try bridgeKeychain.setString("account-a", forKey: KeychainKey.userID)
            let bridgeContainer = makeContainer(keychain: bridgeKeychain)
            bridgeContainer.authStore.setPhaseForTesting(.authenticated(user("account-a")))
            let bridgeLease = try #require(
                bridgeContainer.authStore.activateAuthenticatedSession(ownerID: "account-a")
            )
            let parkedBridgeWork = ParkedAuthenticatedWorkProbe()
            bridgeContainer.measurementsStore.seriesHydrationTask = Task { await parkedBridgeWork.run() }
            let anchorCleanup = AnchorCleanupSpy()
            bridgeContainer.authStore.setOnLogoutCleanup { owner in
                anchorCleanup.record(owner: owner)
            }

            await bridgeContainer.unauthorizedRef.invoke()

            // The awaited bridge must have completed the anchor cleanup for the
            // captured pre-wipe owner before it returned — a detached cleanup
            // outlives this point and races replacement admission.
            let anchorCleanupCompleted = anchorCleanup.count == 1
                && anchorCleanup.lastOwner == "account-a"
            let admitted = await bridgeContainer.authStore.beginAuthenticationTransition()
            if admitted { bridgeContainer.authStore.finishAuthenticationTransition() }
            let bridgeOrderingHolds = !bridgeLease.isCurrent
                && parkedBridgeWork.isFinished
                && anchorCleanupCompleted
                && bridgeContainer.authStore.phase == .unauthenticated
                && admitted
            await drainPlantedTask(bridgeContainer)

            let logoutFacts = "logout(leaseInvalidated \(!logoutLease.isCurrent), "
                + "drained \(parkedLogoutWork.isFinished), tail \(cascadeTail.entries.count))"
            let bridgeFacts = "bridge(leaseInvalidated \(!bridgeLease.isCurrent), "
                + "drained \(parkedBridgeWork.isFinished), anchorCleanups \(anchorCleanup.count))"
            let orderingReason = "EXPECTED_RED: terminal cleanup outlived replacement admission — "
                + "\(logoutFacts) \(bridgeFacts)"
            #expect(logoutOrderingHolds && bridgeOrderingHolds, "\(orderingReason)")
        }

        // MARK: - Deletion boundary

        /// A successful native deletion keeps replacement admission excluded
        /// through invalidation, drain, and the owner-partition/local cleanup
        /// cascade; only afterwards is the terminal state published and B
        /// admitted. A failed deletion performs none of the terminal
        /// invalidation and leaves account A's lease live.
        @Test
        func successfulDeletionDrainsBeforeReplacementAndFailedDeletionPreservesA() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try keychain.setString("refresh-a", forKey: KeychainKey.refreshToken)
            try keychain.setString("owner-a", forKey: KeychainKey.userID)
            let container = makeContainer(keychain: keychain)
            let store = try makeDeletionAuthStore(container: container, keychain: keychain)
            store.localCleanupHook = { @MainActor [weak container] in
                await container?.performFullLocalLogout(reason: .accountDeleted)
            }
            store.setPhaseForTesting(.authenticated(user("owner-a")))
            let leaseA = try #require(store.activateAuthenticatedSession(ownerID: "owner-a"))
            let parkedWork = ParkedAuthenticatedWorkProbe()
            container.measurementsStore.seriesHydrationTask = Task { await parkedWork.run() }

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"deleted":true}}"#.utf8)
                )
            }

            let deleted = await store.deleteAccount()
            let admitted = await store.beginAuthenticationTransition()
            if admitted { store.finishAuthenticationTransition() }
            let successOrderingHolds = deleted
                && !leaseA.isCurrent
                && parkedWork.isFinished
                && store.phase == .unauthenticated
                && admitted
            await drainPlantedTask(container)

            // Failed deletion — the live lease must survive untouched.
            store.setPhaseForTesting(.authenticated(user("owner-a")))
            let retryLease = try #require(store.activateAuthenticatedSession(ownerID: "owner-a"))
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Internal"}"#.utf8)
                )
            }

            let failedDeletionSucceeded = await store.deleteAccount()
            let failurePhasePreserved: Bool = if case let .authenticated(owner) = store.phase {
                owner.id == "owner-a"
            } else {
                false
            }
            let failurePreservesA = !failedDeletionSucceeded
                && retryLease.isCurrent
                && failurePhasePreserved

            let successFacts = "success(deleted \(deleted), leaseInvalidated \(!leaseA.isCurrent), "
                + "drained \(parkedWork.isFinished), admitted \(admitted))"
            let deletionReason = "EXPECTED_RED: deletion boundary admitted replacement before drain — "
                + "\(successFacts) failurePreservesA \(failurePreservesA)"
            #expect(successOrderingHolds && failurePreservesA, "\(deletionReason)")
        }

        // MARK: - Switch server

        /// Switch-server must tear the old session down completely — shared
        /// lease invalidated, owned tasks cancelled and awaited — before any
        /// persisted/runtime server mutation or pairing admission can proceed.
        @Test
        func switchServerDrainsBeforeServerMutationAndPairing() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try keychain.setString("account-a", forKey: KeychainKey.userID)
            let container = makeContainer(keychain: keychain)
            container.authStore.setPhaseForTesting(.authenticated(user("account-a")))
            let lease = try #require(
                container.authStore.activateAuthenticatedSession(ownerID: "account-a")
            )
            let parkedWork = ParkedAuthenticatedWorkProbe()
            container.measurementsStore.seriesHydrationTask = Task { await parkedWork.run() }

            await container.handleLocalLogout()

            let oldSessionQuiescent = !lease.isCurrent && parkedWork.isFinished
            await drainPlantedTask(container)

            // Leg 2 (06-05 Task 4) — the production `switchServer(to:)`
            // coordinator: the persisted server mutation and pairing
            // publication must follow the complete old-session teardown.
            let coordinatorBase = InMemoryKeychain()
            try coordinatorBase.setString("bearer-a", forKey: KeychainKey.authToken)
            try coordinatorBase.setString("refresh-a", forKey: KeychainKey.refreshToken)
            try coordinatorBase.setString("account-a", forKey: KeychainKey.userID)
            let coordinatorParked = ParkedAuthenticatedWorkProbe()
            let coordinatorKeychain = ServerSwitchKeychainSpy(base: coordinatorBase) {
                coordinatorParked.isFinished
            }
            let coordinatorContainer = makeContainer(keychain: coordinatorKeychain)
            coordinatorContainer.authStore.setPhaseForTesting(.authenticated(user("account-a")))
            let coordinatorLease = try #require(
                coordinatorContainer.authStore.activateAuthenticatedSession(ownerID: "account-a")
            )
            coordinatorContainer.measurementsStore.seriesHydrationTask = Task {
                await coordinatorParked.run()
            }
            let replacementURL = try #require(URL(string: "https://replacement.healthlog.local"))

            try await coordinatorContainer.switchServer(to: replacementURL)

            let mutationFollowedDrain = coordinatorKeychain.drainedWhenServerURLWasWritten == true
                && coordinatorBase.getString(forKey: KeychainKey.serverURL) == replacementURL.absoluteString
                && coordinatorBase.getString(forKey: KeychainKey.authToken) == nil
                && coordinatorBase.getString(forKey: KeychainKey.userID) == nil
                && !coordinatorLease.isCurrent
                && coordinatorParked.isFinished
                && coordinatorContainer.authStore.phase == .unauthenticated
            await drainPlantedTask(coordinatorContainer)

            #expect(
                oldSessionQuiescent && mutationFollowedDrain,
                "EXPECTED_RED: server replacement preceded old-session drain — leaseInvalidated \(!lease.isCurrent), drained \(parkedWork.isFinished), coordinatorMutationFollowedDrain \(mutationFollowedDrain)"
            )
        }
    }

#endif // !SWIFT_PACKAGE

// swiftlint:enable force_unwrapping

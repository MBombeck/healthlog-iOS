// Locks the R4 §3.1 capability surface. `BackendAvailability` folds sync-mode +
// auth-phase + reachability into one observable. The load-bearing invariant for
// this groundwork: a normal paired + authenticated install reports every
// capability flag `true` (zero behaviour change), while standalone / signed-out
// installs flip `hasServer` / `isReachable` / the flags off.
//
// Refs: .planning/v0100-marathon/R4-offline-architecture.md §3.1.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("BackendAvailability capability surface")
    struct BackendAvailabilityTests {
        /// No-op passkey service — `AuthService.init` requires the protocol but
        /// none of these tests touch it.
        private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
            func register(
                challenge _: String, rpId _: String, rpName _: String,
                userID _: String, userName _: String, displayName _: String,
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyRegistration {
                throw HLError.unknown("noop")
            }

            func assert(
                challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyAssertion {
                throw HLError.unknown("noop")
            }
        }

        /// Controllable reachability stub. `online` is fixed for the lifetime of
        /// the stream — sufficient for the state-derivation assertions here (the
        /// online→offline edge is exercised separately via `pushOnline`).
        private final class StubReach: ReachabilityProviding, @unchecked Sendable {
            let online: Bool
            init(online: Bool) {
                self.online = online
            }

            var isOnlineStream: AsyncStream<Bool> {
                get async { AsyncStream { c in c.yield(online)
                    c.finish()
                } }
            }

            func isCurrentlyOnline() async -> Bool {
                online
            }
        }

        private func makeStores(mode: SyncMode?) -> (SyncModeStore, AuthStore) {
            let keychain = InMemoryKeychain()
            let suite = "hl.tests.backendavail.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            if let mode {
                defaults.set(mode.rawValue, forKey: SyncModeStore.storageKey)
            }
            let sync = SyncModeStore(defaults: defaults)
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let store = AuthStore(auth: auth, keychain: keychain, syncMode: sync)
            return (sync, store)
        }

        private func makeUser() -> User {
            User(id: "u1", email: nil, username: nil, displayName: "T", createdAt: .now)
        }

        // MARK: - Paired-path invariant (the whole point of the groundwork)

        @Test("Paired + authenticated + online → every flag true, fully reachable")
        func pairedAuthedOnline() {
            let (sync, auth) = makeStores(mode: .paired)
            auth.setPhaseForTesting(.authenticated(makeUser()))
            let avail = BackendAvailability(syncMode: sync, authStore: auth)
            avail.start(reachability: StubReach(online: true))

            #expect(avail.mode == .paired)
            #expect(avail.hasServer)
            #expect(avail.isAuthenticated)
            // online flag starts true (default) — fully reachable without waiting
            // on the stream tick.
            #expect(avail.isReachable)
            #expect(avail.canShowHealthScore)
            #expect(avail.canShowCloudInsights)
            #expect(avail.canShowPersonalRecords)
            #expect(avail.canSyncMultiDevice)
        }

        // MARK: - Standalone

        @Test("Standalone → no server, no capabilities, not reachable")
        func standalone() {
            let (sync, auth) = makeStores(mode: .standalone)
            auth.setPhaseForTesting(.standalone)
            let avail = BackendAvailability(syncMode: sync, authStore: auth)

            #expect(avail.mode == .standalone)
            #expect(!avail.hasServer)
            #expect(!avail.isAuthenticated)
            #expect(!avail.isReachable)
            #expect(!avail.canShowHealthScore)
            #expect(!avail.canSyncMultiDevice)
        }

        // MARK: - Paired but session lost (401-cascade outcome)

        @Test("Paired but unauthenticated → server still exists, but not reachable")
        func pairedSessionLost() {
            let (sync, auth) = makeStores(mode: .paired)
            auth.setPhaseForTesting(.unauthenticated)
            let avail = BackendAvailability(syncMode: sync, authStore: auth)

            // Server surfaces still EXIST (the install is paired) — they don't
            // collapse to the standalone placeholder just because the token
            // expired; they show their normal signed-out / re-auth path.
            #expect(avail.hasServer)
            #expect(avail.canShowHealthScore)
            // …but we can't actually talk to it until re-auth.
            #expect(!avail.isAuthenticated)
            #expect(!avail.isReachable)
        }

        @Test("Authenticating (mid-onboarding) counts as authenticated for reachability")
        func authenticatingCountsAsAuthed() {
            let (sync, auth) = makeStores(mode: .paired)
            auth.setPhaseForTesting(.authenticating(makeUser()))
            let avail = BackendAvailability(syncMode: sync, authStore: auth)

            #expect(avail.isAuthenticated)
            #expect(avail.isReachable)
        }

        // MARK: - Offline gates `isReachable` but NOT `hasServer`

        @Test("Paired + authed + offline → surfaces exist, but not fresh-reachable")
        func pairedAuthedOffline() async {
            let (sync, auth) = makeStores(mode: .paired)
            auth.setPhaseForTesting(.authenticated(makeUser()))
            let avail = BackendAvailability(syncMode: sync, authStore: auth)
            avail.start(reachability: StubReach(online: false))

            // Let the consumer loop drain the single `false` yield.
            try? await Task.sleep(nanoseconds: 50_000_000)

            #expect(avail.hasServer)
            #expect(avail.canShowHealthScore) // surface still exists offline
            #expect(!avail.isOnline)
            #expect(!avail.isReachable) // …but a fresh request wouldn't reach it
        }

        // MARK: - Default (no mode resolved yet) → paired expectation

        @Test("No mode resolved (fresh paired default) → treated as paired")
        func noModeDefaultsToPaired() {
            let (sync, auth) = makeStores(mode: nil)
            auth.setPhaseForTesting(.unknown)
            let avail = BackendAvailability(syncMode: sync, authStore: auth)

            #expect(avail.mode == .paired)
            #expect(avail.hasServer)
        }
    }

#endif

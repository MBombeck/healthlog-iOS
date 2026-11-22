// Locks the R4 §3.1 capability surface. `BackendAvailability` folds the
// auth phase + reachability into one observable: an authenticated, online
// install is reachable; a signed-out or offline one is not.
//
// Refs: .planning/v0100-marathon/R4-offline-architecture.md §3.1.

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

        private func makeAuthStore() -> AuthStore {
            let keychain = InMemoryKeychain()
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            return AuthStore(auth: auth, keychain: keychain)
        }

        private func makeUser() -> User {
            User(id: "u1", email: nil, username: nil, displayName: "T", createdAt: .now)
        }

        @Test("Authenticated + online → fully reachable")
        func authenticatedOnline() {
            let auth = makeAuthStore()
            auth.setPhaseForTesting(.authenticated(makeUser()))
            let avail = BackendAvailability(authStore: auth)
            avail.start(reachability: StubReach(online: true))

            #expect(avail.isAuthenticated)
            // online flag starts true (default) — fully reachable without waiting
            // on the stream tick.
            #expect(avail.isReachable)
        }

        // MARK: - Session lost (401-cascade outcome)

        @Test("Unauthenticated → not reachable")
        func sessionLost() {
            let auth = makeAuthStore()
            auth.setPhaseForTesting(.unauthenticated)
            let avail = BackendAvailability(authStore: auth)

            #expect(!avail.isAuthenticated)
            #expect(!avail.isReachable)
        }

        @Test("Authenticating (mid-onboarding) counts as authenticated for reachability")
        func authenticatingCountsAsAuthed() {
            let auth = makeAuthStore()
            auth.setPhaseForTesting(.authenticating(makeUser()))
            let avail = BackendAvailability(authStore: auth)

            #expect(avail.isAuthenticated)
            #expect(avail.isReachable)
        }

        // MARK: - Offline gates `isReachable`

        @Test("Authenticated + offline → not fresh-reachable")
        func authenticatedOffline() async {
            let auth = makeAuthStore()
            auth.setPhaseForTesting(.authenticated(makeUser()))
            let avail = BackendAvailability(authStore: auth)
            avail.start(reachability: StubReach(online: false))

            // Let the consumer loop drain the single `false` yield.
            try? await Task.sleep(nanoseconds: 50_000_000)

            #expect(!avail.isOnline)
            #expect(!avail.isReachable) // a fresh request wouldn't reach it
        }

        @Test("Unknown phase → not authenticated")
        func unknownPhase() {
            let auth = makeAuthStore()
            auth.setPhaseForTesting(.unknown)
            let avail = BackendAvailability(authStore: auth)

            #expect(!avail.isAuthenticated)
        }
    }

#endif

// Locks the bootstrap rules: a Keychain token resolves to `.authenticated`
// without re-onboarding, everything else to `.unauthenticated`. The update
// path of an install that stored the retired offline mode is covered by
// `StandaloneRetirementUpdatePathTests`.
//
// Refs: M2-A11 §8.1 (migration path), PROJECT_GUIDE.md (server-first invariant).

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("AuthStore.bootstrap migration semantics")
    struct AuthStoreBootstrapTests {
        /// Minimal no-op passkey service — `bootstrap` never touches passkey,
        /// but `AuthService.init` requires the protocol.
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

        private func makeStore(
            tokenPresent: Bool,
            userIDPresent: Bool
        ) throws -> (AuthStore, InMemoryKeychain) {
            let keychain = InMemoryKeychain()
            if tokenPresent {
                try? keychain.setString("test-bearer-token", forKey: KeychainKey.authToken)
            }
            if userIDPresent {
                try? keychain.setString("user-abc-123", forKey: KeychainKey.userID)
            }
            // Defaults suite isolated per-test.
            let suite = "hl.tests.bootstrap.\(UUID().uuidString)"
            let defaults = try #require(
                UserDefaults(suiteName: suite),
                "isolated UserDefaults suite must be constructible"
            )
            defaults.removePersistentDomain(forName: suite)
            // Bootstrap uses only `keychain.getString` + `auth.isAuthenticated`;
            // no network — but AuthService still needs an APIClient to compile.
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(
                environment: env,
                keychain: keychain
            )
            let authService = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let store = AuthStore(auth: authService, keychain: keychain, defaults: defaults)
            return (store, keychain)
        }

        @Test("Fresh install: no token → .unauthenticated")
        func freshInstall() async throws {
            let (store, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            await store.bootstrap()
            #expect(store.phase == .unauthenticated)
        }

        @Test("Token present → .authenticated without re-onboarding")
        func tokenPresentAuthenticates() async throws {
            let (store, _) = try makeStore(tokenPresent: true, userIDPresent: true)
            await store.bootstrap()
            if case .authenticated = store.phase {
                // expected
            } else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
            }
        }

        @Test("Cold-launch seeds avatar initials from persisted name hint (no more \"?\")")
        func coldLaunchSeedsInitialsFromHint() async throws {
            let (store, keychain) = try makeStore(tokenPresent: true, userIDPresent: true)
            // The login path persisted the best-available label; bootstrap must
            // rehydrate it so the avatar paints real initials before the server
            // profile lands instead of the "?" monogram (build-75 feedback).
            try? keychain.setString("Anna-Lena Fischer", forKey: KeychainKey.userDisplayName)
            await store.bootstrap()
            guard case let .authenticated(user) = store.phase else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
                return
            }
            #expect(user.displayName == "Anna-Lena Fischer")
            #expect(user.avatarInitials == "AF")
            #expect(user.avatarInitials != "?")
        }

        @Test("Cold-launch without a persisted hint still yields \"?\" (graceful)")
        func coldLaunchNoHintFallsBackToQuestionMark() async throws {
            let (store, _) = try makeStore(tokenPresent: true, userIDPresent: true)
            await store.bootstrap()
            guard case let .authenticated(user) = store.phase else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
                return
            }
            #expect(user.displayName == nil)
            #expect(user.avatarInitials == "?")
        }

        @Test("isUnlockEligible is true for .authenticated only")
        func unlockEligibility() {
            #expect(AuthStore.Phase.unknown.isUnlockEligible == false)
            #expect(AuthStore.Phase.unauthenticated.isUnlockEligible == false)
            let user = User(id: "x", email: nil, username: nil, displayName: nil, createdAt: nil)
            #expect(AuthStore.Phase.authenticated(user).isUnlockEligible == true)
            // `.authenticating(user)` is the intermediate server-
            // branch phase that runs between server-login resolving and the
            // post-permission `completeOnboarding()` flip. The user is still
            // inside OnboardingFlow at that point, so the biometric-lock gate
            // must NOT engage — AuthenticatedShell has not mounted yet.
            #expect(AuthStore.Phase.authenticating(user).isUnlockEligible == false)
        }

        @Test("completeOnboarding promotes .authenticating(user) to .authenticated(user)")
        func completeOnboardingPromotes() throws {
            let (store, keychain) = try makeStore(tokenPresent: false, userIDPresent: false)
            let user = User(id: "u-1", email: "u@example.com", username: nil, displayName: nil, createdAt: nil)
            // Drop the store directly into `.authenticating` — emulates what
            // `AuthService.login` resolution would write.
            store.setPhaseForTesting(.authenticating(user))
            store.completeOnboarding()
            #expect(store.phase == .authenticated(user))
            _ = keychain
        }

        @Test("completeOnboarding is a no-op outside .authenticating")
        func completeOnboardingIdempotent() throws {
            let (store, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            // From .unauthenticated — must NOT promote to .authenticated.
            store.setPhaseForTesting(.unauthenticated)
            store.completeOnboarding()
            #expect(store.phase == .unauthenticated)
        }

        @Test("returnToSignIn drops a signed-in store back to .unauthenticated")
        func returnToSignInUnauthenticates() throws {
            let (store, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            let user = User(id: "u-1", email: nil, username: nil, displayName: nil, createdAt: nil)
            store.setPhaseForTesting(.authenticated(user))
            store.returnToSignIn()
            #expect(store.phase == .unauthenticated)
        }
    }

#endif

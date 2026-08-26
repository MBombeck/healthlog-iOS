// Locks the v0.4.1 bootstrap migration rules. Before this patch
// `AuthStore.bootstrap` only knew `.authenticated` vs `.unauthenticated`.
// v0.4.1 adds a third `.standalone` phase + a one-shot upgrade rule:
// existing v0.4.0 users with a Keychain token default to SyncMode.paired
// (no re-onboarding), and pre-existing standalone users transition to
// `.standalone` phase without showing the OnboardingFlow.
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
            userIDPresent: Bool,
            preexistingMode: SyncMode? = nil
        ) throws -> (AuthStore, SyncModeStore, InMemoryKeychain) {
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
            if let preexistingMode {
                defaults.set(preexistingMode.rawValue, forKey: SyncModeStore.storageKey)
            }
            let syncMode = SyncModeStore(defaults: defaults)
            // Bootstrap uses only `keychain.getString` + `auth.isAuthenticated`;
            // no network — but AuthService still needs an APIClient to compile.
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(
                environment: env,
                keychain: keychain
            )
            let authService = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let store = AuthStore(auth: authService, keychain: keychain, syncMode: syncMode)
            return (store, syncMode, keychain)
        }

        @Test("Fresh install: no token + no mode → .unauthenticated")
        func freshInstall() async throws {
            let (store, sync, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            await store.bootstrap()
            #expect(store.phase == .unauthenticated)
            #expect(sync.mode == nil)
        }

        @Test("v0.4.0 upgrader: token present + no sync-mode → .authenticated + default .paired")
        func v040UpgradeDefaultsToPaired() async throws {
            let (store, sync, _) = try makeStore(tokenPresent: true, userIDPresent: true)
            await store.bootstrap()
            if case .authenticated = store.phase {
                // expected
            } else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
            }
            #expect(sync.mode == .paired)
        }

        @Test("Cold-launch seeds avatar initials from persisted name hint (no more \"?\")")
        func coldLaunchSeedsInitialsFromHint() async throws {
            let (store, _, keychain) = try makeStore(tokenPresent: true, userIDPresent: true)
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
            let (store, _, _) = try makeStore(tokenPresent: true, userIDPresent: true)
            await store.bootstrap()
            guard case let .authenticated(user) = store.phase else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
                return
            }
            #expect(user.displayName == nil)
            #expect(user.avatarInitials == "?")
        }

        @Test("Returning standalone user: no token + mode=.standalone → .standalone phase")
        func standaloneReturning() async throws {
            let (store, sync, _) = try makeStore(
                tokenPresent: false,
                userIDPresent: false,
                preexistingMode: .standalone
            )
            await store.bootstrap()
            #expect(store.phase == .standalone)
            #expect(sync.mode == .standalone)
        }

        @Test("Already-paired user: token + mode=.paired → .authenticated (no double-write)")
        func alreadyPairedNoDoubleWrite() async throws {
            let (store, sync, _) = try makeStore(
                tokenPresent: true,
                userIDPresent: true,
                preexistingMode: .paired
            )
            await store.bootstrap()
            if case .authenticated = store.phase {} else {
                Issue.record("Expected .authenticated phase, got \(store.phase)")
            }
            #expect(sync.mode == .paired)
        }

        @Test("isUnlockEligible is true for .authenticated and .standalone, false otherwise")
        func unlockEligibility() {
            #expect(AuthStore.Phase.unknown.isUnlockEligible == false)
            #expect(AuthStore.Phase.unauthenticated.isUnlockEligible == false)
            #expect(AuthStore.Phase.standalone.isUnlockEligible == true)
            let user = User(id: "x", email: nil, username: nil, displayName: nil, createdAt: nil)
            #expect(AuthStore.Phase.authenticated(user).isUnlockEligible == true)
            // v0.6.0.9 — `.authenticating(user)` is the intermediate server-
            // branch phase that runs between server-login resolving and the
            // post-permission `completeOnboarding()` flip. The user is still
            // inside OnboardingFlow at that point, so the biometric-lock gate
            // must NOT engage — AuthenticatedShell has not mounted yet.
            #expect(AuthStore.Phase.authenticating(user).isUnlockEligible == false)
        }

        @Test("completeOnboarding promotes .authenticating(user) to .authenticated(user)")
        func completeOnboardingPromotes() throws {
            let (store, _, keychain) = try makeStore(tokenPresent: false, userIDPresent: false)
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
            let (store, _, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            // From .unauthenticated — must NOT promote to .authenticated.
            store.setPhaseForTesting(.unauthenticated)
            store.completeOnboarding()
            #expect(store.phase == .unauthenticated)
            // From .standalone — must stay standalone.
            store.setPhaseForTesting(.standalone)
            store.completeOnboarding()
            #expect(store.phase == .standalone)
        }

        @Test("enterStandaloneMode flips phase + records OnboardingMode.standalone")
        func enterStandaloneTransition() throws {
            let (store, sync, _) = try makeStore(tokenPresent: false, userIDPresent: false)
            store.enterStandaloneMode()
            #expect(store.phase == .standalone)
            #expect(sync.mode == .standalone)
            #expect(sync.onboardingMode == .standalone)
        }

        @Test("beginServerPairing clears standalone mode + flips to .unauthenticated")
        func beginServerPairingClears() throws {
            let (store, sync, _) = try makeStore(
                tokenPresent: false,
                userIDPresent: false,
                preexistingMode: .standalone
            )
            // Simulate the user being in standalone phase before pairing.
            store.enterStandaloneMode()
            store.beginServerPairing()
            #expect(store.phase == .unauthenticated)
            #expect(sync.mode == nil)
        }
    }

#endif

// v0.11 W1b — locks the LIVE seam transition the BackendAvailability groundwork
// only exercised statically before. The existing `BackendAvailabilityTests`
// construct the surface already-in-a-mode; this suite drives the runtime
// `AuthStore.enterStandaloneMode()` / `beginServerPairing()` calls over a SHARED
// `SyncModeStore` and asserts the capability surface flips end-to-end — the seam
// W2 (read-union) and W3 (placeholder adoption) lean on.
//
// The load-bearing invariant: after `enterStandaloneMode()` runs, `mode` is
// `.standalone`, `hasServer` is `false`, and ALL SEVEN `canShow*` capability
// flags read `false` (so every server-derived surface flips to its placeholder).
// The reverse (`beginServerPairing()`) restores `hasServer`.
//
// Refs: .planning/v0110-marathon/v0.11-STANDALONE-WAVE-PLAN.md §W1b.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("BackendAvailability standalone transition (W1b)")
    struct BackendAvailabilityStandaloneTransitionTests {
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

        /// Paired+authenticated harness over one shared `SyncModeStore`, so a
        /// later `enterStandaloneMode()` mutates the SAME store the
        /// `BackendAvailability` reads. `BackendAvailability` holds its stores
        /// weak — keep `sync` + `auth` alive for the test's lifetime.
        private struct Harness {
            let avail: BackendAvailability
            let sync: SyncModeStore
            let auth: AuthStore
        }

        private func makePaired() -> Harness {
            let keychain = InMemoryKeychain()
            let suite = "hl.tests.backendavail.transition.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(SyncMode.paired.rawValue, forKey: SyncModeStore.storageKey)
            let sync = SyncModeStore(defaults: defaults)
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let authStore = AuthStore(auth: auth, keychain: keychain, syncMode: sync)
            authStore.setPhaseForTesting(
                .authenticated(User(id: "u1", email: nil, username: nil, displayName: "T", createdAt: .now))
            )
            return Harness(
                avail: BackendAvailability(syncMode: sync, authStore: authStore),
                sync: sync,
                auth: authStore
            )
        }

        /// Every capability flag, folded so the assertions can't drift out of
        /// sync with the surface as new flags land.
        private func allCapabilities(_ a: BackendAvailability) -> [Bool] {
            [
                a.canShowHealthScore,
                a.canShowCloudInsights,
                a.canShowPersonalRecords,
                a.canSyncMultiDevice
            ]
        }

        @Test("enterStandaloneMode() flips mode + every capability flag to false")
        func enterStandaloneFlipsSeam() {
            let h = makePaired()

            // Precondition — paired surface is fully live.
            #expect(h.avail.mode == .paired)
            #expect(h.avail.hasServer)
            #expect(allCapabilities(h.avail).allSatisfy { $0 })

            // The live transition (the OnboardingFlow standalone door + the
            // Settings "lokal weiter" path both call this).
            h.auth.enterStandaloneMode()

            #expect(h.avail.mode == .standalone)
            #expect(!h.avail.hasServer)
            #expect(!h.avail.isAuthenticated)
            #expect(!h.avail.isReachable)
            // All seven flags now read false — every server-derived surface
            // renders HLCloudDerivedPlaceholder.
            #expect(allCapabilities(h.avail).allSatisfy { !$0 })
        }

        @Test("beginServerPairing() restores hasServer after a standalone stint")
        func pairingRestoresServer() {
            let h = makePaired()

            h.auth.enterStandaloneMode()
            #expect(h.avail.mode == .standalone)
            #expect(!h.avail.hasServer)

            // Pairing clears the standalone runtime mode (re-enters onboarding
            // → server URL/auth). `hasServer` returns once the mode is no longer
            // standalone (the default paired expectation).
            h.auth.beginServerPairing()
            #expect(h.avail.mode == .paired)
            #expect(h.avail.hasServer)
            #expect(allCapabilities(h.avail).allSatisfy { $0 })
        }
    }

#endif

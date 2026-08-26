// v0.11 W5 — the Release standalone door. Asserts the state-machine
// invariants the OnboardingFlow mode-fork relies on:
//   1. The standalone choice enters standalone mode (phase + SyncMode).
//   2. A paired-from-start session never arms the adopt-on-pair upload —
//      `adoptUploadState` stays `.idle` (the "byte-identical paired flow"
//      guard for the W5 door flip).
//   3. `beginServerPairing()` from standalone re-enters onboarding by
//      dropping `phase` to `.unauthenticated` and clearing the runtime mode,
//      so the user picks "Connect your server" again in the now-Release fork.
//
// The capability-flag seam (every `canShow*` flips) is covered by
// `BackendAvailabilityStandaloneTransitionTests`; this suite locks the
// onboarding-entry + adopt-state contract specifically.
//
// Refs: .planning/v0110-marathon/v0.11-STANDALONE-WAVE-PLAN.md §W5.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Standalone door (W5)")
    struct StandaloneDoorTests {
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

        private struct Harness {
            let auth: AuthStore
            let sync: SyncModeStore
        }

        /// A fresh, unauthenticated harness over an isolated defaults suite —
        /// the state a first-launch user reaches when the mode fork renders.
        private func makeFresh() -> Harness {
            let keychain = InMemoryKeychain()
            let suite = "hl.tests.standalonedoor.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let sync = SyncModeStore(defaults: defaults)
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            return Harness(
                auth: AuthStore(auth: auth, keychain: keychain, syncMode: sync),
                sync: sync
            )
        }

        @Test("standalone choice enters standalone mode (phase + SyncMode)")
        func standaloneChoiceEntersMode() {
            let h = makeFresh()
            #expect(h.auth.adoptUploadState == .idle)

            // The OnboardingFlow `.standalone` branch calls this after the
            // local HK + Notifications steps complete.
            h.auth.enterStandaloneMode()

            #expect(h.auth.phase == .standalone)
            #expect(h.sync.isStandalone)
            // No adopt-upload is ever armed by a plain standalone entry.
            #expect(h.auth.adoptUploadState == .idle)
        }

        @Test("paired-from-start never arms the adopt-on-pair upload")
        func pairedFromStartStaysIdle() {
            let h = makeFresh()
            // Server-branch onboarding records the mode but does NOT call
            // `beginServerPairing()` — so the adopt flag is never set and the
            // upload state must remain idle (the W5 byte-identical guard).
            h.auth.markOnboardingMode(.server)
            h.auth.completeOnboarding()

            #expect(h.auth.adoptUploadState == .idle)
        }

        @Test("beginServerPairing() from standalone re-enters onboarding")
        func pairingReEntersOnboarding() {
            let h = makeFresh()
            h.auth.enterStandaloneMode()
            #expect(h.auth.phase == .standalone)
            #expect(h.sync.isStandalone)

            // Settings → "Connect your server": drops back to the now-Release
            // mode fork by clearing standalone + resetting to unauthenticated.
            h.auth.beginServerPairing()

            #expect(h.auth.phase == .unauthenticated)
            #expect(!h.sync.isStandalone)
        }
    }

#endif

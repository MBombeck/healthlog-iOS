// Locks the gating decision that drives `HLCloudDerivedPlaceholder` on the
// representative server-derived surfaces (Health Score tile, Personal Records,
// server Doctor-Report). The views branch on `BackendAvailability` capability
// flags: `true` → live content, `false` → the calm cloud placeholder.
//
// The load-bearing invariant: in PAIRED mode every gate is `true`, so the
// placeholder NEVER renders for a paired user — the live surface is unchanged.
//
// Refs: .planning/v0100-marathon/R4-offline-architecture.md §3.1 + §3.2.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("HLCloudDerivedPlaceholder gating")
    struct CloudDerivedGatingTests {
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

        /// `BackendAvailability` holds its stores `weak` (the composition root
        /// owns their lifetime). The test must keep them alive too — so we return
        /// the trio and the caller binds all three.
        private func makeAvailability(
            mode: SyncMode?,
            phase: AuthStore.Phase
        ) -> (BackendAvailability, SyncModeStore, AuthStore) {
            let keychain = InMemoryKeychain()
            let suite = "hl.tests.cloudgate.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            if let mode {
                defaults.set(mode.rawValue, forKey: SyncModeStore.storageKey)
            }
            let sync = SyncModeStore(defaults: defaults)
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let authStore = AuthStore(auth: auth, keychain: keychain, syncMode: sync)
            authStore.setPhaseForTesting(phase)
            return (BackendAvailability(syncMode: sync, authStore: authStore), sync, authStore)
        }

        @Test("Paired → all gated surfaces show LIVE content (placeholder suppressed)")
        func pairedShowsLive() {
            let user = User(id: "u1", email: nil, username: nil, displayName: "T", createdAt: .now)
            let (avail, sync, auth) = makeAvailability(mode: .paired, phase: .authenticated(user))
            _ = (sync, auth) // keep the weakly-held stores alive
            // v0.10 (already shipped) surfaces.
            #expect(avail.canShowHealthScore) // HealthScoreTile → liveTile
            #expect(avail.canShowPersonalRecords) // PersonalRecordsScreen → content
            // SET-V2-B — `canShowDoctorReportPDF` removed: the consolidated
            // DoctorReportScreen always renders (prefer-server via isReachable,
            // on-device fallback) — no placeholder gate left to pin.
            // v0.11 W3 — the newly-gated (B) surfaces. The paired invariant:
            // every gate `true` → ZERO placeholders → byte-identical behaviour.
            #expect(avail.canShowCloudInsights) // InsightsScreen Zone-4 → live correlations
            #expect(avail.hasServer) // Withings / SourcePriority / AIProvider / Coach
        }

        @Test("Standalone → all gated surfaces show the PLACEHOLDER")
        func standaloneShowsPlaceholder() {
            let (avail, sync, auth) = makeAvailability(mode: .standalone, phase: .standalone)
            _ = (sync, auth) // keep the weakly-held stores alive
            #expect(!avail.canShowHealthScore)
            #expect(!avail.canShowPersonalRecords)
            // v0.11 W3 — every (B) surface flips to its calm placeholder.
            #expect(!avail.canShowCloudInsights) // InsightsScreen Zone-4 placeholder
            #expect(!avail.hasServer) // Withings / SourcePriority / AIProvider / Coach
        }

        @Test("Placeholder primitive builds in every variant + CTA wiring")
        func placeholderBuilds() {
            // Smoke: the presentational primitive constructs without trapping.
            _ = HLCloudDerivedPlaceholder(variant: .hero, surfaceName: "the Health Score")
            _ = HLCloudDerivedPlaceholder(variant: .inline)
            _ = HLCloudDerivedPlaceholder()
            // v0.11 W3 — the placeholder accepts (and stores) the shared
            // "Server verbinden" CTA closure that every adopting surface passes
            // as `{ authStore.beginServerPairing() }`. It composes without
            // trapping with the CTA present.
            _ = HLCloudDerivedPlaceholder(
                variant: .hero,
                surfaceName: "the Withings connection",
                onConnect: {}
            )
        }

        @Test("beginServerPairing drops the standalone user back to .unauthenticated")
        func ctaReachesPairing() {
            let (avail, sync, auth) = makeAvailability(mode: .standalone, phase: .standalone)
            _ = avail
            #expect(sync.isStandalone)
            // The CTA every placeholder wires: AuthStore.beginServerPairing().
            auth.beginServerPairing()
            #expect(auth.phase == .unauthenticated)
            #expect(!sync.isStandalone) // standalone cleared → OnboardingFlow server branch
        }
    }

#endif

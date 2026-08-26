import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// PB1 Reconcile (H3) — locks the new decline-persistence contract that
/// closes the nag-loop after a user declines `AIConsentSheet`. Pre-PB1
/// the decline only cleared the sheet's `pendingConsentProvider`; on the
/// next tab switch `evaluateConsentGate` re-presented unconditionally.
/// The contract verified here:
///
/// 1. `decline(for:)` persists a timestamp readable by `declinedAt(for:)`
///    AND surfaced by the convenience `wasDeclined(for:)` predicate.
/// 2. `grant(for:)` clears any prior decline — granting supersedes.
/// 3. `revoke(for:)` clears BOTH the grant and the declined marker so
///    Settings-initiated revoke returns the user to a neutral state.
/// 4. `requestExplicitPrompt()` bumps a monotonic token observable from
///    `AuthenticatedShell`, the only legitimate path to re-present the
///    sheet after a decline.
@Suite("AIConsentStore — decline + revoke + explicit prompt (PB1 H3)")
@MainActor
struct AIConsentStoreTests {
    @Test("decline(for:) persists timestamp and surfaces via wasDeclined()")
    func declinePersistsTimestamp() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)
        #expect(store.wasDeclined(for: .anthropic) == false)
        #expect(store.declinedAt(for: .anthropic) == nil)

        store.decline(for: .anthropic)

        #expect(store.wasDeclined(for: .anthropic))
        #expect(store.declinedAt(for: .anthropic) != nil)
        // Decline must NOT auto-grant.
        #expect(store.hasConsent(for: .anthropic) == false)
    }

    @Test("decline persists across store re-instantiation (survives app restart)")
    func declineSurvivesRestart() {
        // Reusing the same keychain mirrors the Keychain item surviving a
        // process death — the production AIConsentStore is stateless beyond
        // its keychain backing, so re-allocating proves persistence.
        let keychain = InMemoryKeychain()
        let first = AIConsentStore(keychain: keychain)
        first.decline(for: .openai)

        let secondLaunch = AIConsentStore(keychain: keychain)

        #expect(secondLaunch.wasDeclined(for: .openai))
        // Crucially: `evaluateConsentGate` will read this on the next tab
        // switch and SUPPRESS auto-presentation. That's the contract that
        // closes the nag-loop.
    }

    @Test("decline is per-provider — declining Anthropic does not affect OpenAI")
    func declineIsPerProvider() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)

        store.decline(for: .anthropic)

        #expect(store.wasDeclined(for: .anthropic))
        #expect(store.wasDeclined(for: .openai) == false)
        #expect(store.wasDeclined(for: .local) == false)
    }

    @Test("grant(for:) supersedes a prior decline — declined marker is cleared")
    func grantClearsPriorDecline() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)
        store.decline(for: .anthropic)
        #expect(store.wasDeclined(for: .anthropic))

        store.grant(for: .anthropic)

        #expect(store.hasConsent(for: .anthropic))
        #expect(
            store.wasDeclined(for: .anthropic) == false,
            "grant must clear the declined flag so the user is back in the standard flow"
        )
    }

    @Test("revoke(for:) clears grant AND declined state (neutral reset)")
    func revokeClearsBothFlags() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)
        store.grant(for: .anthropic)
        // Simulate a previous decline that's still on disk for a different
        // historical reason — revoke should normalize to neutral.
        store.decline(for: .anthropic)
        // After decline, hasConsent stays true (the grant persists). Revoke
        // explicitly clears both.
        store.revoke(for: .anthropic)

        #expect(store.hasConsent(for: .anthropic) == false)
        #expect(store.wasDeclined(for: .anthropic) == false)
    }

    @Test("revokeAllOthers preserves the kept provider and clears the rest")
    func revokeAllOthersBehaviour() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)
        store.grant(for: .anthropic)
        store.grant(for: .openai)
        store.grant(for: .local)

        store.revokeAllOthers(keep: .openai)

        #expect(store.hasConsent(for: .openai))
        #expect(store.hasConsent(for: .anthropic) == false)
        #expect(store.hasConsent(for: .local) == false)
    }

    @Test("requestExplicitPrompt() bumps the observable token")
    func explicitPromptTokenBumps() {
        let store = AIConsentStore(keychain: InMemoryKeychain())
        let before = store.explicitPromptToken

        store.requestExplicitPrompt()
        let afterOne = store.explicitPromptToken
        store.requestExplicitPrompt()
        let afterTwo = store.explicitPromptToken

        #expect(afterOne != before, "token must change so onChange(of:) fires")
        #expect(afterTwo != afterOne, "successive calls must produce distinct tokens")
    }

    // MARK: - Task #49 — single remote-AI master opt-in

    @Test("isAnyProviderGranted() is false on a fresh store (undecided user → OFF)")
    func anyProviderGrantedDefaultsFalse() {
        let store = AIConsentStore(keychain: InMemoryKeychain())
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("isAnyProviderGranted() becomes true after a real-provider grant (toggle reads ON)")
    func anyProviderGrantedAfterGrant() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)

        store.grant(for: .anthropic)

        #expect(store.isAnyProviderGranted(), "a prior AIConsentSheet grant must read as the master toggle ON")
    }

    @Test("isAnyProviderGranted() returns to false after revoking the only grant (toggle OFF)")
    func anyProviderGrantedAfterRevoke() {
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain)
        store.grant(for: .openai)
        #expect(store.isAnyProviderGranted())

        store.revoke(for: .openai)

        #expect(store.isAnyProviderGranted() == false, "revoking the last grant closes the master opt-in")
    }

    @Test("isAnyProviderGranted() survives store re-instantiation (grant persists in keychain)")
    func anyProviderGrantedSurvivesRestart() {
        let keychain = InMemoryKeychain()
        AIConsentStore(keychain: keychain).grant(for: .anthropic)

        let secondLaunch = AIConsentStore(keychain: keychain)

        #expect(secondLaunch.isAnyProviderGranted(), "a granted user stays ON across restarts (preserved opt-in)")
    }

    @Test("isAnyProviderGranted() ignores the permissive .unconfigured arm")
    func anyProviderGrantedIgnoresUnconfigured() {
        let store = AIConsentStore(keychain: InMemoryKeychain())
        // grant(for: .unconfigured) is a no-op; hasConsent(.unconfigured) is
        // permissive — but the master opt-in must only count real providers.
        store.grant(for: .unconfigured)
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("hasConsent(for: .unconfigured) is always true (no traffic happens anyway)")
    func unconfiguredIsAlwaysPermissive() {
        let store = AIConsentStore(keychain: InMemoryKeychain())
        #expect(store.hasConsent(for: .unconfigured))
        // And decline/grant for unconfigured are no-ops.
        store.decline(for: .unconfigured)
        #expect(store.wasDeclined(for: .unconfigured) == false)
        store.grant(for: .unconfigured)
        #expect(store.hasConsent(for: .unconfigured))
    }

    // MARK: - Task #53 — three-way AI source choice (mode → gating)

    /// Builds a store with an isolated UserDefaults suite so the on-device flag
    /// never leaks across tests or into the host app's standard defaults.
    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    @Test("fresh store resolves to .none (privacy-first default → all surfaces hidden)")
    func freshStoreModeIsNone() {
        let store = makeStore()
        #expect(store.aiMode == .none)
        #expect(store.isOnDeviceEnabled == false)
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("setMode(.onDevice) enables the local arm and grants nothing off-device")
    func setOnDeviceMode() {
        let store = makeStore()
        store.setMode(.onDevice, activeProvider: .unconfigured)
        #expect(store.aiMode == .onDevice)
        #expect(store.isOnDeviceEnabled)
        // On-device transmits nothing → no provider consent is recorded.
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("setMode(.online) with a provider fires the consent prompt, no auto-grant")
    func setOnlineModeRequestsConsent() {
        let store = makeStore()
        let before = store.explicitPromptToken
        store.setMode(.online, activeProvider: .anthropic)
        // The prompt is requested (the sheet's onAccept grants); mode stays
        // .none until the grant actually lands — never an auto-grant.
        #expect(store.explicitPromptToken != before)
        #expect(store.aiMode == .none)
        #expect(store.isOnDeviceEnabled == false)
    }

    @Test("setMode(.online) becomes .online once the consent grant lands (the #50 fetch path)")
    func onlineModeResolvesAfterGrant() {
        let store = makeStore()
        store.setMode(.online, activeProvider: .anthropic)
        // Simulate the AIConsentSheet onAccept → grant(for:).
        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)
        #expect(store.isAnyProviderGranted())
    }

    @Test("the arms are mutually exclusive — picking .onDevice revokes any prior online grant")
    func onDeviceRevokesOnlineGrant() {
        let store = makeStore()
        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)

        store.setMode(.onDevice, activeProvider: .anthropic)

        #expect(store.aiMode == .onDevice)
        #expect(store.isAnyProviderGranted() == false, "switching to on-device must stop off-device traffic")
    }

    @Test("picking .online clears the on-device flag (mutual exclusion)")
    func onlineClearsOnDevice() {
        let store = makeStore()
        store.setMode(.onDevice, activeProvider: .anthropic)
        #expect(store.aiMode == .onDevice)

        store.setMode(.online, activeProvider: .anthropic)
        store.grant(for: .anthropic)

        #expect(store.aiMode == .online)
        #expect(store.isOnDeviceEnabled == false)
    }

    @Test("setMode(.none) closes every gate — clears on-device flag AND revokes grants")
    func noneClosesEverything() {
        let store = makeStore()
        store.grant(for: .anthropic)
        store.setMode(.none, activeProvider: .anthropic)
        #expect(store.aiMode == .none)
        #expect(store.isAnyProviderGranted() == false)

        store.setMode(.onDevice, activeProvider: .unconfigured)
        store.setMode(.none, activeProvider: .unconfigured)
        #expect(store.aiMode == .none)
        #expect(store.isOnDeviceEnabled == false)
    }

    @Test("Task #49 prior grant migrates to .online (back-compat — no parallel flag)")
    func priorGrantMigratesToOnline() {
        // Mirror a user who granted consent under Task #49 (the only persisted
        // state was the per-provider Keychain grant). The new mode resolution
        // must read that as .online with no migration step.
        let keychain = InMemoryKeychain()
        AIConsentStore(keychain: keychain).grant(for: .openai)

        let migrated = AIConsentStore(keychain: keychain, defaults: makeIsolatedDefaults())

        #expect(migrated.aiMode == .online, "a prior Task #49 grant reads back as .online")
        #expect(migrated.isOnDeviceEnabled == false)
    }

    @Test("on-device flag persists across store re-instantiation (UI-pref survives restart)")
    func onDeviceFlagSurvivesRestart() {
        let suite = makeIsolatedDefaults()
        AIConsentStore(keychain: InMemoryKeychain(), defaults: suite)
            .setMode(.onDevice, activeProvider: .unconfigured)

        let secondLaunch = AIConsentStore(keychain: InMemoryKeychain(), defaults: suite)

        #expect(secondLaunch.aiMode == .onDevice)
        #expect(secondLaunch.isOnDeviceEnabled)
    }

    // MARK: - M1 (Audit-2) — pending `.online` intent without a provider

    @Test("M1: picking .online without a provider persists a pending intent, aiMode stays .none")
    func onlineWithoutProviderPersistsIntent() {
        let store = makeStore()
        #expect(store.isOnlineIntentPending == false)

        store.setMode(.online, activeProvider: .unconfigured)

        // The intent is held so the Settings picker keeps showing Online…
        #expect(store.isOnlineIntentPending)
        // …but the app-wide gates stay closed — no grant could land, so aiMode
        // resolves .none and remoteAIEnabled stays false (never an empty box).
        #expect(store.aiMode == .none)
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("M1: pending intent survives store re-instantiation (UI-pref persists)")
    func intentSurvivesRestart() {
        let defaults = makeIsolatedDefaults()
        let first = AIConsentStore(keychain: InMemoryKeychain(), defaults: defaults)
        first.setMode(.online, activeProvider: .unconfigured)
        #expect(first.isOnlineIntentPending)

        let secondLaunch = AIConsentStore(keychain: InMemoryKeychain(), defaults: defaults)
        #expect(secondLaunch.isOnlineIntentPending, "the picker must still show Online after a relaunch")
    }

    @Test("M1: a grant fulfils the pending intent and clears it")
    func grantClearsPendingIntent() {
        let store = makeStore()
        store.setMode(.online, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending)

        // User configures a provider, then the consent sheet grants it.
        store.grant(for: .anthropic)

        #expect(store.isOnlineIntentPending == false, "a real grant supersedes the intent")
        #expect(store.aiMode == .online)
    }

    @Test("M1: picking .none or .onDevice clears any pending online intent")
    func switchingArmsClearsIntent() {
        let store = makeStore()
        store.setMode(.online, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending)

        store.setMode(.onDevice, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending == false)

        store.setMode(.online, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending)
        store.setMode(.none, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending == false)
    }

    @Test("M1: picking .online WITH a provider does not leave a stale intent")
    func onlineWithProviderNoStaleIntent() {
        let store = makeStore()
        store.setMode(.online, activeProvider: .anthropic)
        // A provider exists → the consent prompt path is used, no intent held.
        #expect(store.isOnlineIntentPending == false)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        // A UUID suite name is always valid (only the reserved global/registration
        // domains return nil), so the fallback is unreachable — it satisfies the
        // no-force-unwrap rule without a real branch.
        UserDefaults(suiteName: "AIModeTests.\(UUID().uuidString)") ?? .standard
    }
}

/// v0.13 — locks the BYO-key (client-side device→provider) arm of ``AIMode``.
/// The contract: `grantBYO` is the only thing that flips `aiMode` to `.byoKey`;
/// the arms stay mutually exclusive (BYO revokes server + on-device, and the
/// other arms revoke BYO); one BYO provider is active at a time; the pending
/// intent mirrors the M1 online-intent so the picker holds the selection during
/// inline key entry. Resolution is client-key-wins as a defensive tiebreak.
@Suite("AIConsentStore — BYO-key arm (v0.13)")
@MainActor
struct AIConsentStoreBYOTests {
    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    @Test("fresh store: no BYO grant, aiMode resolves .none")
    func freshHasNoBYO() {
        let store = makeStore()
        #expect(store.isAnyBYOKeyGranted() == false)
        #expect(store.hasBYOConsent(for: .openAI) == false)
        #expect(store.aiMode == .none)
    }

    @Test("grantBYO flips aiMode to .byoKey and records the consent")
    func grantBYOResolvesByoKey() {
        let store = makeStore()
        store.grantBYO(for: .anthropic)
        #expect(store.aiMode == .byoKey)
        #expect(store.isAnyBYOKeyGranted())
        #expect(store.hasBYOConsent(for: .anthropic))
    }

    @Test("grantBYO is mutually exclusive — revokes server grants and clears on-device")
    func grantBYORevokesOtherArms() {
        let store = makeStore()
        store.grant(for: .anthropic) // a prior server grant (.online)
        store.setOnDeviceEnabled(true)
        #expect(store.aiMode == .byoKey || store.aiMode == .online) // pre-state sanity

        store.grantBYO(for: .openAI)

        #expect(store.aiMode == .byoKey)
        #expect(store.isAnyProviderGranted() == false, "BYO must stop server-mediated AI traffic")
        #expect(store.isOnDeviceEnabled == false, "BYO must clear the on-device arm")
        // Back-compat invariant: remoteAIEnabled == (aiMode == .online) still holds.
        #expect((store.aiMode == .online) == store.isAnyProviderGranted())
    }

    @Test("only one BYO provider is active at a time")
    func oneBYOProviderAtATime() {
        let store = makeStore()
        store.grantBYO(for: .openAI)
        store.grantBYO(for: .anthropic)
        #expect(store.hasBYOConsent(for: .anthropic))
        #expect(store.hasBYOConsent(for: .openAI) == false, "switching BYO providers revokes the prior one")
    }

    @Test("picking .none / .onDevice / .online revokes every BYO grant")
    func otherArmsRevokeBYO() {
        let store = makeStore()
        store.grantBYO(for: .gemini)
        #expect(store.aiMode == .byoKey)

        store.setMode(.onDevice, activeProvider: .unconfigured)
        #expect(store.isAnyBYOKeyGranted() == false)
        #expect(store.aiMode == .onDevice)

        store.grantBYO(for: .gemini)
        store.setMode(.none, activeProvider: .unconfigured)
        #expect(store.isAnyBYOKeyGranted() == false)

        store.grantBYO(for: .gemini)
        store.setMode(.online, activeProvider: .anthropic) // revokeAllBYO happens before consent
        #expect(store.isAnyBYOKeyGranted() == false)
    }

    @Test("setMode(.byoKey) holds a pending intent; grantBYO clears it")
    func byoKeyIntentLifecycle() {
        let store = makeStore()
        #expect(store.isBYOKeyIntentPending == false)

        store.setMode(.byoKey, activeProvider: .unconfigured)
        // Intent held so the picker keeps "Own key" selected + entry card open…
        #expect(store.isBYOKeyIntentPending)
        // …but no grant yet → aiMode has not flipped.
        #expect(store.aiMode == .none)

        store.grantBYO(for: .openAI)
        #expect(store.isBYOKeyIntentPending == false, "a real BYO grant supersedes the intent")
        #expect(store.aiMode == .byoKey)
    }

    @Test("setMode(.byoKey) leaves an existing server grant intact until a BYO grant lands")
    func byoKeyIntentDoesNotDestroyServerSetup() {
        let store = makeStore()
        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)

        store.setMode(.byoKey, activeProvider: .anthropic)
        // Merely tapping "Own key" must NOT revoke the working server setup —
        // aiMode stays .online (never an empty box) until the key is entered.
        #expect(store.aiMode == .online)
        #expect(store.isBYOKeyIntentPending)
    }

    @Test("BYO grant + back-compat: remoteAIEnabled is false under .byoKey")
    func byoKeyKeepsRemoteAIInvariant() {
        let store = makeStore()
        store.grantBYO(for: .openAI)
        // remoteAIEnabled == isAnyProviderGranted() == (aiMode == .online).
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.aiMode == .byoKey)
    }

    @Test("BYO grant persists across store re-instantiation (Keychain-backed)")
    func byoGrantSurvivesRestart() {
        let keychain = InMemoryKeychain()
        AIConsentStore(keychain: keychain, defaults: makeIsolatedDefaults()).grantBYO(for: .gemini)

        let secondLaunch = AIConsentStore(keychain: keychain, defaults: makeIsolatedDefaults())
        #expect(secondLaunch.aiMode == .byoKey)
        #expect(secondLaunch.hasBYOConsent(for: .gemini))
    }

    @Test("revokeAllBYO clears every BYO grant (logout-cascade contract)")
    func revokeAllBYOClearsEverything() {
        let store = makeStore()
        store.grantBYO(for: .anthropic)
        store.revokeAllBYO()
        #expect(store.isAnyBYOKeyGranted() == false)
        #expect(store.aiMode == .none)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIModeBYOTests.\(UUID().uuidString)") ?? .standard
    }
}

/// v0.14.7 COACH-redesign — locks the `revision` observable-bump contract that
/// fixes the "consent did nothing until app restart" routing no-op. `aiMode` is
/// computed from UserDefaults + Keychain (untracked by Observation), so a surface
/// must read the stored `revision` to be invalidated on a mode flip. Every
/// mode-input mutator must bump it so the Coach body re-routes live.
@Suite("AIConsentStore — revision observable bump (COACH-redesign)")
@MainActor
struct AIConsentStoreRevisionTests {
    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    @Test("fresh store starts at revision 0")
    func freshRevisionIsZero() {
        #expect(makeStore().revision == 0)
    }

    @Test("setMode(.onDevice) bumps revision so a reader re-routes")
    func setModeOnDeviceBumps() {
        let store = makeStore()
        let before = store.revision
        store.setMode(.onDevice, activeProvider: .unconfigured)
        #expect(store.revision > before)
        // Sanity: the mode actually flipped (the resolution the body reads).
        #expect(store.aiMode == .onDevice)
    }

    @Test("grant bumps revision (nested-consent Accept re-routes the surface)")
    func grantBumps() {
        let store = makeStore()
        let before = store.revision
        store.grant(for: .anthropic)
        #expect(store.revision > before)
        #expect(store.aiMode == .online)
    }

    @Test("revoke bumps revision")
    func revokeBumps() {
        let store = makeStore()
        store.grant(for: .anthropic)
        let before = store.revision
        store.revoke(for: .anthropic)
        #expect(store.revision > before)
    }

    @Test("grantBYO bumps revision")
    func grantBYOBumps() {
        let store = makeStore()
        let before = store.revision
        store.grantBYO(for: .anthropic)
        #expect(store.revision > before)
        #expect(store.aiMode == .byoKey)
    }

    @Test("each direct mode-input mutator bumps revision")
    func eachMutatorBumps() {
        let store = makeStore()
        var last = store.revision
        for mutate in mutators {
            mutate(store)
            #expect(store.revision > last, "every mode-input mutator must bump revision")
            last = store.revision
        }
    }

    /// The set of direct mutators the Coach routing depends on. `setMode` is
    /// covered transitively (it calls these), so the individual setters are the
    /// canonical coverage surface.
    private var mutators: [(AIConsentStore) -> Void] {
        [
            { $0.setOnDeviceEnabled(true) },
            { $0.setOnlineIntentPending(true) },
            { $0.setBYOKeyIntentPending(true) },
            { $0.grant(for: .anthropic) },
            { $0.revoke(for: .anthropic) },
            { $0.grantBYO(for: .gemini) },
            { $0.revokeBYO(for: .gemini) },
            // N5.1 — decline changes wasDeclined()/declinedAt() output, so the
            // consent-gate readers must be invalidated too.
            { $0.decline(for: .anthropic) }
        ]
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIModeRevisionTests.\(UUID().uuidString)") ?? .standard
    }
}

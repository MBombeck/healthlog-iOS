import Foundation
@testable import HealthLog
import Testing

/// **RCA-coach-ai (v0.15.1) — the server-managed External-AI "dead pick".**
///
/// Operator symptom (real device): Settings shows *External AI* selected, yet the
/// Coach FAB + Insights coach surfaces are nowhere and Coach answers stay
/// on-device. Root cause: for the admin/server-managed provider
/// (`managedBy:"server"`, per-user `provider:null` → `resolvedProvider ==
/// .unconfigured`), picking External AI called `setMode(.online, .unconfigured)`,
/// which fell to the intent-only `else` branch — NO consent sheet, NO grant —
/// so `aiMode` stayed `.none`. Every Coach gate keys off `aiMode != .none`
/// (FAB/Insights) and routing keys off `aiMode == .online` (server arm), so the
/// pick was dead: surfaces hidden + sends fell to on-device.
///
/// The fix makes the server-managed pick reach the shell's explicit-consent path
/// (`requestExplicitPrompt()` → server-managed sheet → `grantServerManaged()` +
/// minted `ai_full` ConsentReceipt) so the grant actually lands and `aiMode`
/// becomes `.online`. Consent is NOT bypassed — only the sheet is opened.
///
/// These tests pin the decision logic + the resulting store transitions.
@MainActor
@Suite("Settings server-managed External-AI pick reaches consent (RCA-coach-ai)")
struct SettingsServerManagedPickTests {
    private func makeStore() throws -> AIConsentStore {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.smpick.\(UUID().uuidString)"))
        return AIConsentStore(keychain: keychain, defaults: defaults)
    }

    // MARK: - 1. The pick decision: server-managed not-consented → request consent

    @Test("picking External AI with server-managed available + not consented requests consent")
    func serverManagedPickRequestsConsent() {
        #expect(
            SettingsAIScreen.shouldRequestServerManagedConsent(
                isServerManagedAvailable: true,
                hasServerManagedConsent: false
            )
        )
    }

    @Test("already consented → no re-prompt (working setup is left alone)")
    func alreadyConsentedNoReprompt() {
        #expect(
            SettingsAIScreen.shouldRequestServerManagedConsent(
                isServerManagedAvailable: true,
                hasServerManagedConsent: true
            ) == false
        )
    }

    @Test("not server-managed → the dedicated path does not fire (per-provider path owns it)")
    func notServerManagedNoServerManagedPrompt() {
        #expect(
            SettingsAIScreen.shouldRequestServerManagedConsent(
                isServerManagedAvailable: false,
                hasServerManagedConsent: false
            ) == false
        )
    }

    // MARK: - 2. The pick is no longer dead: it resolves to aiMode == .online

    /// Reproduces the exact dead-pick sequence the operator hit, then proves the
    /// fix: a server-managed External-AI pick now reaches a consent grant
    /// (modelled as the sheet's accept calling `grantServerManaged()`), and the
    /// end state is `aiMode == .online` (NOT the intent-only `.none`).
    @Test("server-managed External-AI pick resolves to aiMode .online (not a dead .none)")
    func serverManagedPickResolvesOnline() throws {
        let store = try makeStore()

        // Pre-state: the old `setMode(.online, .unconfigured)` path — intent only.
        store.setMode(.online, activeProvider: .unconfigured)
        #expect(store.isOnlineIntentPending) // picker SHOWS External AI…
        #expect(store.aiMode == .none) // …but aiMode is the dead intent-only state.

        // The fix: the pick now requests the explicit consent prompt (we assert
        // the decision is to request it), and the shell's accept grants the
        // server-managed scope + mints the receipt.
        #expect(
            SettingsAIScreen.shouldRequestServerManagedConsent(
                isServerManagedAvailable: true,
                hasServerManagedConsent: store.hasServerManagedConsent()
            )
        )
        let before = store.explicitPromptToken
        store.requestExplicitPrompt() // handleModePick → shell presents server-managed sheet
        #expect(store.explicitPromptToken == before + 1)

        store.grantServerManaged() // AIConsentSheet.onAccept (serverManaged) — receipt minted alongside

        // End state: the pick is alive — Coach surfaces appear, routing prefers server.
        #expect(store.aiMode == .online)
        #expect(store.isAnyProviderGranted())
        #expect(store.isOnlineIntentPending == false) // the stale intent is cleared by the grant
    }

    // MARK: - 3. Declined-once re-engage

    /// A prior decline must NOT permanently strand the user on-device: re-picking
    /// External AI re-presents consent. `requestExplicitPrompt()` deliberately
    /// bypasses the `wasServerManagedDeclined` auto-suppression, and the decision
    /// helper does not consult the decline marker — so the re-pick still fires.
    @Test("declined once, re-picking External AI re-engages consent and can reach .online")
    func declinedOnceReengages() throws {
        let store = try makeStore()
        store.declineServerManaged()
        #expect(store.wasServerManagedDeclined())
        #expect(store.aiMode == .none)

        // Re-pick: the decision still requests consent (decline is not consulted).
        #expect(
            SettingsAIScreen.shouldRequestServerManagedConsent(
                isServerManagedAvailable: true,
                hasServerManagedConsent: store.hasServerManagedConsent()
            )
        )
        let before = store.explicitPromptToken
        store.requestExplicitPrompt()
        #expect(store.explicitPromptToken == before + 1)

        store.grantServerManaged() // accept clears the decline + enables
        #expect(store.wasServerManagedDeclined() == false)
        #expect(store.aiMode == .online)
    }

    // MARK: - 4. Routing: the server arm wins for an EXTERNAL-AI user (v0152 C3)

    /// The production `prefersServerArm` closure (`AppContainer+SpeziLLM`). Mirrors
    /// the wiring exactly so the routing contract is pinned against the real store
    /// transitions: prefer the server arm when External AI is the active arm
    /// (`aiMode == .online`) OR the user EXPRESSED External AI but the grant hasn't
    /// landed yet (`isOnlineIntentPending`).
    private func prefersServerArm(_ store: AIConsentStore) -> @MainActor () -> Bool {
        { store.aiMode == .online || store.isOnlineIntentPending }
    }

    /// **v0152 W-COACH-CLEANUP (C3) — the b198 felt regression.** The operator
    /// selected External AI but the coach answered on-device. Root cause: while the
    /// server-managed grant was pending (`aiMode == .none`, intent pending), the
    /// b198 on-device-reach surfacing answered him LOCALLY. The fix prefers the
    /// server arm for the EXPRESSED external pick too, so the sheet surfaces the
    /// consent CTA (`serverFallbackNeedsConsent`) instead of routing on-device.
    @Test("EXTERNAL-AI pick prefers server arm even before the grant lands (no silent on-device)")
    func externalPickPrefersServerBeforeGrant() throws {
        let store = try makeStore()
        let prefers = prefersServerArm(store)

        store.setMode(.online, activeProvider: .unconfigured) // intent-only (grant pending)
        #expect(store.aiMode == .none) // grant not yet resolved…
        #expect(store.isOnlineIntentPending) // …but the EXTERNAL pick is expressed
        #expect(prefers()) // → routing prefers server → consent CTA, NOT silent on-device

        store.grantServerManaged() // the grant lands
        #expect(store.aiMode == .online)
        #expect(store.isOnlineIntentPending == false)
        #expect(prefers()) // → still server (now the active arm)
    }

    /// And a genuine on-device chooser must still route on-device — the C3 fix must
    /// not regress users who deliberately picked on-device.
    @Test("genuine on-device pick is not pushed to the server arm")
    func onDevicePickStaysOnDevice() throws {
        let store = try makeStore()
        store.setMode(.onDevice, activeProvider: .unconfigured, requestOnlineConsent: false)
        #expect(store.aiMode == .onDevice)
        #expect(store.isOnlineIntentPending == false)
        #expect(prefersServerArm(store)() == false)
    }

    /// The unexpressed `.none` user (never picked anything) must NOT be pushed to
    /// the server arm — they keep the private on-device path (the C3 fix is scoped
    /// to an EXPRESSED external pick, not a fresh install).
    @Test("unexpressed .none user keeps on-device (server arm not preferred)")
    func unexpressedNoneStaysOnDevice() throws {
        let store = try makeStore()
        #expect(store.aiMode == .none)
        #expect(store.isOnlineIntentPending == false)
        #expect(prefersServerArm(store)() == false)
    }
}

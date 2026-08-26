import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.8 cycle-marathon — locks the **grant-round-trip** the operator's
/// device bug cluster broke: granting consent for a *resolved* provider must read
/// back as consented (Bug 2 — "I accepted but it still says consent missing"),
/// and switching to `.none` must turn it fully off + bump `revision` so the
/// Settings picker re-renders to None (Bug 3 — "can't disable"). The shell's
/// accept path now grants the *resolved* provider (never `.unconfigured`); this
/// suite pins the store contract that round-trip depends on so it can't regress.
@Suite("AIConsentStore — grant round-trip (v0.14.8 Bug 2 / Bug 3)")
@MainActor
struct AIConsentStoreGrantRoundTripTests {
    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    @Test("granting the resolved provider reads back as consented (Bug 2)")
    func grantResolvedProviderReadsBack() {
        let store = makeStore()
        // Simulate the shell accept path: the gate resolved a REAL provider
        // (not `.unconfigured`), so the sheet's onAccept grants it.
        let resolved = AIProvider.anthropic
        #expect(store.hasConsent(for: resolved) == false)
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.aiMode == .none)

        store.grant(for: resolved)

        // The grant must be visible immediately — no "Zustimmung fehlt" after accept.
        #expect(store.hasConsent(for: resolved))
        #expect(store.isAnyProviderGranted())
        #expect(store.aiMode == .online)
    }

    @Test("granting .unconfigured is a silent no-op — never reads as consented (Bug 2 root cause)")
    func grantUnconfiguredIsNoOp() {
        let store = makeStore()
        // This is the exact shape that broke trust on device: the gate fired
        // before the provider config loaded, so the captured provider was
        // `.unconfigured`. The shell now guards this upstream; the store must
        // also never silently report success for it.
        store.grant(for: .unconfigured)
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.aiMode == .none)
    }

    @Test("switching to .none after a grant turns External AI fully off (Bug 3)")
    func switchToNoneDisablesAfterGrant() {
        let store = makeStore()
        store.grant(for: .openai)
        #expect(store.aiMode == .online)
        #expect(store.isAnyProviderGranted())

        // The picker's "No assistant" path → setMode(.none).
        store.setMode(.none, activeProvider: .openai)

        #expect(store.aiMode == .none, "tapping None must move the resolved mode off External AI")
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.hasConsent(for: .openai) == false)
    }

    @Test("the full round-trip bumps revision on grant AND on disable (picker re-renders both ways)")
    func roundTripBumpsRevision() {
        let store = makeStore()
        let atStart = store.revision

        store.grant(for: .anthropic)
        let afterGrant = store.revision
        #expect(afterGrant > atStart, "grant must bump revision so the picker snaps to External AI")

        store.setMode(.none, activeProvider: .anthropic)
        let afterDisable = store.revision
        #expect(afterDisable > afterGrant, "disabling must bump revision so the picker snaps to None")
    }

    @Test("disable is reachable even when the resolved provider is .unconfigured (Bug 3 — off must always work)")
    func disableWorksWithUnconfiguredProvider() {
        let store = makeStore()
        // A prior grant exists (e.g. server provider was known when granted),
        // but the live provider now resolves `.unconfigured` (config not loaded).
        // The off-path must still revoke every grant — disable can't be gated on
        // a known server provider.
        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)

        // setMode(.none) revokes ALL real providers regardless of activeProvider.
        store.setMode(.none, activeProvider: .unconfigured)

        #expect(store.aiMode == .none)
        #expect(store.isAnyProviderGranted() == false)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIModeRoundTripTests.\(UUID().uuidString)") ?? .standard
    }
}

/// v0.14.8 cycle-marathon — Bug 1 store-side carry-through. Onboarding records an
/// `.online` choice WITHOUT granting (the shell that hosts the consent sheet
/// isn't mounted, so `requestOnlineConsent: false`). Previously the
/// configured-provider branch cleared the online intent anyway, so the pick
/// evaporated and Settings later fired the *first* real consent (felt like a
/// second nag). The store must now persist the intent so `displayedMode` shows
/// `.online` after onboarding and Settings can fulfil it once, in context.
@Suite("AIConsentStore — onboarding online carry-through (v0.14.8 Bug 1)")
@MainActor
struct AIConsentOnlineCarryThroughTests {
    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    @Test("onboarding pick with a provider but no consent-prompt persists the intent")
    func onboardingOnlineWithProviderPersistsIntent() {
        let store = makeStore()
        // Onboarding: a server provider IS configured, but the shell can't host
        // the sheet → requestOnlineConsent: false. No grant lands.
        store.setMode(.online, activeProvider: .anthropic, requestOnlineConsent: false)

        // The choice must survive so the Settings picker shows .online…
        #expect(store.isOnlineIntentPending, "the onboarding online pick must carry through")
        // …but no grant landed, so the app-wide gates stay closed.
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.aiMode == .none)
    }

    @Test("a later grant fulfils the carried-through intent and clears it (no double prompt)")
    func laterGrantFulfilsCarriedThroughIntent() {
        let store = makeStore()
        store.setMode(.online, activeProvider: .anthropic, requestOnlineConsent: false)
        #expect(store.isOnlineIntentPending)

        // Settings presents the data-flow sheet once; onAccept grants.
        store.grant(for: .anthropic)

        #expect(store.isOnlineIntentPending == false, "a real grant supersedes the intent")
        #expect(store.aiMode == .online)
    }

    @Test("interactive pick (requestOnlineConsent: true) still leaves no stale intent")
    func interactivePickNoStaleIntent() {
        let store = makeStore()
        // The Settings/interactive path keeps the default true → fires the sheet,
        // does NOT hold an intent (the sheet will grant or decline).
        store.setMode(.online, activeProvider: .anthropic)
        #expect(store.isOnlineIntentPending == false)
    }

    @Test("carry-through does not clobber an existing grant")
    func carryThroughDoesNotClobberGrant() {
        let store = makeStore()
        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)

        // Re-applying the onboarding-style pick must not flip a granted user back
        // to a mere pending intent.
        store.setMode(.online, activeProvider: .anthropic, requestOnlineConsent: false)
        #expect(store.aiMode == .online)
        #expect(store.isOnlineIntentPending == false)
        #expect(store.isAnyProviderGranted())
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIOnlineCarryThroughTests.\(UUID().uuidString)") ?? .standard
    }
}

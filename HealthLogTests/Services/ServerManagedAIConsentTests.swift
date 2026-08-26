import Foundation
@testable import HealthLog
import Testing

/// **W-B186 COACH-1 (#24) — server/admin-managed AI provider makes the Coach
/// visible + usable without a per-user provider.**
///
/// Server v1.16.16 (#24) added `aiAvailable` + `managedBy` to
/// `GET /api/user/ai-provider`. The previously-`null` admin-managed case now
/// reports `aiAvailable: true`, `managedBy: "server"`. iOS must:
///   - show + serve the Coach in that case (consent targets a server-managed
///     scope, since there is no concrete `AIProvider` to key against),
///   - keep the Coach hidden ONLY when `aiAvailable == false`,
///   - behave EXACTLY as before on an older server that omits both fields.
///
/// Server thread quote (#24): *"`aiAvailable: boolean` — true when ANY provider
/// can answer (personal key, self-hosted local model, OR the operator's
/// server/admin-managed key). `managedBy: "user" | "local" | "server" | null` …
/// Gate Coach visibility on `aiAvailable === true`. `managedBy === "server"` is
/// the case to mint the consent receipt without requiring a personal key."*
@MainActor
@Suite("Server-managed AI provider Coach visibility (W-B186 COACH-1 / #24)")
struct ServerManagedAIConsentTests {
    private func makeStore() throws -> AIConsentStore {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.coach1.\(UUID().uuidString)"))
        return AIConsentStore(keychain: keychain, defaults: defaults)
    }

    // MARK: - DTO decode + resolution (tolerant for older servers)

    @Test("aiAvailable:true managedBy:server with null per-user provider → server-managed available")
    func serverManagedConfigResolves() {
        let config = AIProviderConfig(aiAvailable: true, managedBy: "server")
        #expect(config.resolvedProvider == .unconfigured) // no per-user provider
        #expect(config.managedByResolved == .server)
        #expect(config.aiAvailableResolved == true)
        #expect(config.aiConsentTarget == .providerOpaque)
        #expect(config.isServerAIAvailable)
        #expect(config.usesProviderOpaqueAIConsent)
        #expect(config.isAIExplicitlyUnavailable == false)
    }

    @Test("an available provider unknown to this client uses the provider-opaque consent path")
    func futureProviderUsesProviderOpaqueConsent() {
        let config = AIProviderConfig(
            provider: "FUTURE_OAUTH",
            aiAvailable: true,
            managedBy: "user"
        )

        #expect(config.resolvedProvider == .unconfigured)
        #expect(config.aiAvailableResolved == true)
        #expect(config.aiConsentTarget == .providerOpaque)
        #expect(config.usesProviderOpaqueAIConsent)
        #expect(config.isServerAIAvailable)
        #expect(config.isFullyConfigured)

        let reengage = InsightsScreen.isCoachReengageAvailable(
            aiMode: .none,
            coachFlagEnabled: true,
            hasServer: true,
            resolvedProvider: config.resolvedProvider,
            hasConsentForProvider: false,
            isServerManagedAvailable: config.usesProviderOpaqueAIConsent,
            hasServerManagedConsent: false
        )
        #expect(reengage)
    }

    @Test("aiAvailable:false → genuinely unavailable, Coach stays hidden")
    func explicitlyUnavailable() {
        let config = AIProviderConfig(aiAvailable: false, managedBy: nil)
        #expect(config.aiConsentTarget == .unavailable)
        #expect(config.isServerAIAvailable == false)
        #expect(config.isFullyConfigured == false)
        #expect(config.usesProviderOpaqueAIConsent == false)
        #expect(config.isAIExplicitlyUnavailable)
    }

    @Test("older server (fields absent) is unchanged — nil availability, unknown origin")
    func olderServerTolerantDecode() throws {
        // Exactly the legacy payload: no aiAvailable, no managedBy.
        let json = #"{"provider":null,"hasAnthropicKey":false,"hasOpenaiKey":false,"hasLocalKey":false}"#
        let config = try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
        #expect(config.aiAvailableResolved == nil) // unknown — fall through to per-provider
        #expect(config.managedByResolved == .unknown)
        #expect(config.usesProviderOpaqueAIConsent == false)
        #expect(config.isAIExplicitlyUnavailable == false)
        #expect(config.resolvedProvider == .unconfigured)
        #expect(config.aiConsentTarget == .unavailable)
    }

    @Test("decode tolerates the full new payload round-trip")
    func decodeFullPayload() throws {
        let json = """
        {"provider":null,"hasAnthropicKey":false,"hasOpenaiKey":false,"hasLocalKey":false,\
        "aiAvailable":true,"managedBy":"server"}
        """
        let config = try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
        #expect(config.usesProviderOpaqueAIConsent)
    }

    @Test("a user-configured provider is NOT diverted to the server-managed path")
    func userProviderNotServerManaged() {
        // aiAvailable:true via the user's own Anthropic key; managedBy:user.
        let config = AIProviderConfig(
            provider: "ANTHROPIC",
            hasAnthropicKey: true,
            aiAvailable: true,
            managedBy: "user"
        )
        #expect(config.resolvedProvider == .anthropic)
        #expect(config.aiConsentTarget == .provider(.anthropic))
        #expect(config.isServerAIAvailable)
        #expect(config.usesProviderOpaqueAIConsent == false) // concrete provider wins
    }

    @Test("provider-opaque local AI still follows effective availability")
    func providerOpaqueLocalUsesEffectiveAvailability() {
        let config = AIProviderConfig(aiAvailable: true, managedBy: "local")
        #expect(config.managedByResolved == .local)
        #expect(config.aiConsentTarget == .providerOpaque)
        #expect(config.usesProviderOpaqueAIConsent)
    }

    @Test("all server AI surfaces share the provider-opaque consent decision")
    func sharedConsentDecision() throws {
        let store = try makeStore()
        let opaque = AIProviderConfig(
            provider: "FUTURE_OAUTH",
            aiAvailable: true,
            managedBy: "user"
        )
        let unavailable = AIProviderConfig(
            provider: "ANTHROPIC",
            aiAvailable: false,
            managedBy: "user"
        )

        #expect(AppContainer.hasRequiredServerAIConsent(config: opaque, consentStore: store) == false)
        store.grantServerManaged()
        #expect(AppContainer.hasRequiredServerAIConsent(config: opaque, consentStore: store))
        #expect(AppContainer.hasRequiredServerAIConsent(config: unavailable, consentStore: store) == false)
    }

    // MARK: - Consent store: server-managed grant flips aiMode → .online

    @Test("granting the server-managed scope makes the Coach visible (aiMode .online)")
    func grantServerManagedEnablesCoach() throws {
        let store = try makeStore()
        #expect(store.aiMode == .none) // hidden until consent
        #expect(store.hasServerManagedConsent() == false)

        store.grantServerManaged()

        #expect(store.hasServerManagedConsent())
        #expect(store.isAnyProviderGranted()) // counts as a remote-AI grant
        #expect(store.aiMode == .online) // Coach + per-metric surfaces appear
    }

    @Test("a server-managed decline silences the auto-gate but explicit re-engage still works")
    func serverManagedDeclineThenReengage() throws {
        let store = try makeStore()
        store.declineServerManaged()
        #expect(store.wasServerManagedDeclined())
        #expect(store.aiMode == .none)

        let before = store.explicitPromptToken
        store.requestExplicitPrompt() // the Insights "enable coach" CTA
        #expect(store.explicitPromptToken == before + 1)

        store.grantServerManaged() // accept clears the decline + enables
        #expect(store.wasServerManagedDeclined() == false)
        #expect(store.aiMode == .online)
    }

    @Test("revoking the server-managed scope closes every gate again")
    func revokeServerManagedClosesGate() throws {
        let store = try makeStore()
        store.grantServerManaged()
        #expect(store.aiMode == .online)
        store.revokeServerManaged()
        #expect(store.hasServerManagedConsent() == false)
        #expect(store.isAnyProviderGranted() == false)
        #expect(store.aiMode == .none)
    }

    @Test("setMode(.none) and .onDevice both drop the server-managed grant (mutual exclusivity)")
    func switchingArmsDropsServerManaged() throws {
        let store = try makeStore()
        store.grantServerManaged()
        store.setMode(.none, activeProvider: .unconfigured)
        #expect(store.hasServerManagedConsent() == false)

        store.grantServerManaged()
        store.setMode(.onDevice, activeProvider: .unconfigured)
        #expect(store.hasServerManagedConsent() == false)
        #expect(store.aiMode == .onDevice)
    }

    @Test("the server-managed grant bumps revision so SwiftUI gates re-render")
    func grantBumpsRevision() throws {
        let store = try makeStore()
        let before = store.revision
        store.grantServerManaged()
        #expect(store.revision > before)
    }

    // MARK: - Coach re-engage decision (Insights affordance)

    @Test("server-managed available + not consented → Insights re-engage CTA is offered")
    func reengageOfferedForServerManaged() {
        let available = InsightsScreen.isCoachReengageAvailable(
            aiMode: .none,
            coachFlagEnabled: true,
            hasServer: true,
            resolvedProvider: .unconfigured, // no per-user provider
            hasConsentForProvider: true, // .unconfigured short-circuits true — must NOT block
            isServerManagedAvailable: true,
            hasServerManagedConsent: false
        )
        #expect(available) // #24 — admin-managed is now in scope (was a dead-end before)
    }

    @Test("once the server-managed scope is consented, the re-engage CTA disappears")
    func reengageHiddenAfterServerManagedConsent() {
        let available = InsightsScreen.isCoachReengageAvailable(
            aiMode: .online, // aiMode flipped after grant — affordance only for .none
            coachFlagEnabled: true,
            hasServer: true,
            resolvedProvider: .unconfigured,
            hasConsentForProvider: true,
            isServerManagedAvailable: true,
            hasServerManagedConsent: true
        )
        #expect(available == false)
    }

    @Test("older server (no server-managed flag) keeps the prior behaviour")
    func reengageUnchangedForOlderServer() {
        // The .unconfigured / not-server-managed case stays a hard "no CTA" —
        // exactly as before COACH-1 (we never offer a path we can't fulfil).
        let available = InsightsScreen.isCoachReengageAvailable(
            aiMode: .none,
            coachFlagEnabled: true,
            hasServer: true,
            resolvedProvider: .unconfigured,
            hasConsentForProvider: true,
            isServerManagedAvailable: false,
            hasServerManagedConsent: false
        )
        #expect(available == false)
    }

    @Test("explicit unavailability suppresses stale concrete-provider re-engage")
    func reengageHonorsExplicitUnavailability() {
        let available = InsightsScreen.isCoachReengageAvailable(
            aiMode: .none,
            coachFlagEnabled: true,
            hasServer: true,
            resolvedProvider: .anthropic,
            hasConsentForProvider: false,
            isAIExplicitlyUnavailable: true
        )
        #expect(available == false)
    }
}

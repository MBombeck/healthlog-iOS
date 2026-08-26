import Foundation
@testable import HealthLog
import Testing

/// v0.14.1 — pins the fix for the AI Coach External-AI consent dead-end:
/// "Frag den Coach → Externe KI → Coach starten → Akzeptieren" used to bounce
/// the user BACK to the chooser, because the demo user has no server AI provider
/// → the consent sheet opened with `provider == .unconfigured`, and
/// `AIConsentStore.grant(for: .unconfigured)` is a guard-noop → `aiMode` stayed
/// `.none` → the surface re-rendered the SAME chooser (silent bounce).
///
/// Three reinforcing guarantees under test:
///   1. The picker marks External AI UNAVAILABLE when no provider is configured
///      (so the dead-end is unreachable), and AVAILABLE once one exists.
///   2. Accepting consent for an unconfigured provider is a noop that never
///      flips `aiMode` to `.online` (so the accept-handler must route to the
///      provider-needed step instead of dismissing into a non-working coach).
///   3. The on-device commit resolves `aiMode` to `.onDevice`, which is what
///      re-routes the Coach surface into the live transcript.
/// Plus: the "set up a provider" CTA routes to Settings → Assistant.
@MainActor
@Suite("Coach External-AI consent dead-end (v0.14.1)")
struct CoachExternalAIConsentDeadEndTests {
    // MARK: - 1. Picker marks External AI unavailable when unconfigured

    @Test("coachChoice marks External AI disabled-with-reason when no provider")
    func externalAIDisabledWithoutProvider() {
        let options = AISourceOptions.coachChoice(hasServerProvider: false)
        let external = options.first { $0.mode == .online }
        let onDevice = options.first { $0.mode == .onDevice }

        // External AI is present but NOT selectable — the dead-end is unreachable.
        #expect(external != nil)
        #expect(external?.isAvailable == false)
        // It carries the Assistant-settings recovery so the user can set one up.
        if case let .disabledWithReason(_, recovery) = external?.state {
            #expect(recovery == .openAssistantSettings)
        } else {
            Issue.record("External AI should be disabledWithReason when no provider")
        }
        // On-device stays the working, selectable default.
        #expect(onDevice?.isAvailable == true)
    }

    @Test("coachChoice marks External AI available once a provider exists")
    func externalAIAvailableWithProvider() {
        let options = AISourceOptions.coachChoice(hasServerProvider: true)
        let external = options.first { $0.mode == .online }
        #expect(external?.isAvailable == true)
        if case .available = external?.state {} else {
            Issue.record("External AI should be available when a provider is configured")
        }
    }

    // MARK: - 2. Accept on an unconfigured provider never flips to .online

    @Test("grant(for: .unconfigured) is a noop — aiMode never becomes .online")
    func grantUnconfiguredIsNoop() throws {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.coach.deadend.\(UUID().uuidString)"))
        let store = AIConsentStore(keychain: keychain, defaults: defaults)

        #expect(store.aiMode == .none)
        // This is exactly what the consent sheet's onAccept did for the demo
        // user: grant the resolved (.unconfigured) provider. It must NOT open
        // the .online gate, otherwise the surface would claim a working coach
        // that can't transmit.
        store.grant(for: .unconfigured)
        #expect(store.aiMode == .none)
        #expect(store.isAnyProviderGranted() == false)
    }

    @Test("grant(for: real provider) does flip aiMode to .online")
    func grantRealProviderFlipsOnline() throws {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.coach.deadend.\(UUID().uuidString)"))
        let store = AIConsentStore(keychain: keychain, defaults: defaults)

        store.grant(for: .anthropic)
        #expect(store.aiMode == .online)
        #expect(store.hasConsent(for: .anthropic))
    }

    // MARK: - 3. On-device commit resolves into the coach

    @Test("on-device commit resolves aiMode to .onDevice (routes to transcript)")
    func onDeviceCommitResolvesOnDevice() throws {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.coach.deadend.\(UUID().uuidString)"))
        let store = AIConsentStore(keychain: keychain, defaults: defaults)

        // This is what the chooser's "Start the coach" (on-device pick) does.
        store.setMode(.onDevice, activeProvider: .unconfigured, requestOnlineConsent: false)
        #expect(store.aiMode == .onDevice)
        // No off-device gate opened by the private on-device pick.
        #expect(store.isAnyProviderGranted() == false)
    }

    // MARK: - 4. "Set up a provider" routes to Settings → Assistant

    @Test("requestSettingsAssistant lands on Mehr → Settings → Assistant")
    func providerSetupRoutesToAssistant() {
        let router = AppRouter()
        router.requestSettingsAssistant()
        #expect(router.selectedTab == .more)
        // Pushes .root THEN .assistant → back stack Mehr → Settings → Assistant.
        #expect(router.morePath.count == 2)
    }
}

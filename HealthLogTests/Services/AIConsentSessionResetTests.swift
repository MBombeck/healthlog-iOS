import Foundation
@testable import HealthLog
import Testing

/// A shared device must start every authenticated session without inheriting
/// either off-device consent or the prior user's local-only assistant choice.
/// The local choice is not consent, but it is still user-scoped UI state.
@Suite("AI consent session reset")
@MainActor
struct AIConsentSessionResetTests {
    @Test("Session reset clears local, server, BYO, decline, and pending-intent state")
    func resetClearsEveryUserScopedAIModeInput() {
        let defaults = UserDefaults(suiteName: "AIConsentSessionResetTests.\(UUID().uuidString)") ?? .standard
        let keychain = InMemoryKeychain()
        let store = AIConsentStore(keychain: keychain, defaults: defaults)

        store.grant(for: .anthropic)
        store.decline(for: .openai)
        store.grantServerManaged()
        store.grantBYO(for: .gemini)
        // Deliberately seed the local-only/pending flags last. The public mode
        // mutators normally keep arms exclusive; a previous logout bug was a
        // partial reset, so this test must exercise every persisted input at once.
        store.setOnDeviceEnabled(true)
        store.setOnlineIntentPending(true)
        store.setBYOKeyIntentPending(true)

        store.resetForSessionEnd()

        #expect(store.aiMode == .none)
        #expect(!store.isOnDeviceEnabled)
        #expect(!store.isOnlineIntentPending)
        #expect(!store.isBYOKeyIntentPending)
        #expect(!store.isAnyProviderGranted())
        #expect(!store.hasServerManagedConsent())
        #expect(!store.isAnyBYOKeyGranted())
        #expect(!store.wasDeclined(for: .openai))
    }
}

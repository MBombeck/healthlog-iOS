import Foundation
@testable import HealthLog
import Testing

/// Locks the v0.4.1 sync-mode store. Verifies:
/// 1. Fresh-install default state (no mode persisted yet).
/// 2. `setOnboardingChoice` writes both the historical OnboardingMode key
///    and derives the runtime SyncMode.
/// 3. `setMode` writes the runtime key without touching the historical one.
/// 4. `clearOnLogout` only clears the runtime key (preserves history).
/// 5. `isStandalone` / `isPaired` convenience accessors.
@MainActor
@Suite("SyncModeStore — onboarding-mode persistence")
struct SyncModeStoreTests {
    private func ephemeralStore() throws -> (SyncModeStore, UserDefaults) {
        let suite = "hl.tests.syncmode.\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: suite),
            "isolated UserDefaults suite must be constructible"
        )
        defaults.removePersistentDomain(forName: suite)
        return (SyncModeStore(defaults: defaults), defaults)
    }

    @Test("Fresh install — mode is nil, both convenience getters are false")
    func freshInstallDefault() throws {
        let (store, _) = try ephemeralStore()
        #expect(store.mode == nil)
        #expect(store.onboardingMode == nil)
        #expect(!store.isStandalone)
        #expect(!store.isPaired)
    }

    @Test("setOnboardingChoice(.server) derives SyncMode = .paired")
    func serverChoiceDerivesPaired() throws {
        let (store, defaults) = try ephemeralStore()
        store.setOnboardingChoice(.server)
        #expect(store.onboardingMode == .server)
        #expect(store.mode == .paired)
        #expect(store.isPaired)
        #expect(!store.isStandalone)
        // Persistence check — values survive a fresh store on the same defaults.
        let reloaded = SyncModeStore(defaults: defaults)
        #expect(reloaded.mode == .paired)
        #expect(reloaded.onboardingMode == .server)
    }

    @Test("setOnboardingChoice(.standalone) derives SyncMode = .standalone")
    func standaloneChoiceDerivesStandalone() throws {
        let (store, _) = try ephemeralStore()
        store.setOnboardingChoice(.standalone)
        #expect(store.mode == .standalone)
        #expect(store.isStandalone)
        #expect(!store.isPaired)
    }

    @Test("setOnboardingChoice(.demo) derives SyncMode = .paired (demo is server-backed)")
    func demoChoiceDerivesPaired() throws {
        let (store, _) = try ephemeralStore()
        store.setOnboardingChoice(.demo)
        #expect(store.onboardingMode == .demo)
        #expect(store.mode == .paired)
    }

    @Test("setMode writes runtime key without disturbing onboarding history")
    func setModeKeepsHistory() throws {
        let (store, _) = try ephemeralStore()
        store.setOnboardingChoice(.standalone)
        store.setMode(.paired)
        #expect(store.mode == .paired)
        // History is preserved — analytics can still see the user started
        // standalone before pairing.
        #expect(store.onboardingMode == .standalone)
    }

    @Test("clearOnLogout clears runtime mode but preserves onboarding history")
    func clearPreservesHistory() throws {
        let (store, _) = try ephemeralStore()
        store.setOnboardingChoice(.server)
        store.clearOnLogout()
        #expect(store.mode == nil)
        #expect(store.onboardingMode == .server)
        #expect(!store.isPaired)
        #expect(!store.isStandalone)
    }
}

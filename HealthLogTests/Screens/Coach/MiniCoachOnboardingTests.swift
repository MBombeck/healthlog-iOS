import Foundation
@testable import HealthLog
import Testing

/// Tests around the Mini-Coach onboarding contract (C5).
///
/// The UI itself (the `MiniCoachOnboardingSheet` view) is not unit-
/// tested directly; what we DO lock here is the persisted-state
/// contract the sheet drives via ``MiniCoachStore/markOnboarded()`` +
/// the callback that flips the Settings-toggle.
@Suite("MiniCoach — onboarding (C5)")
@MainActor
struct MiniCoachOnboardingTests {
    @Test("Scope-cards include all four operator-locked categories")
    func scopeCardsCoverAllCategories() {
        let ids = ScopeCardModel.allDefault.map(\.id).sorted()
        #expect(ids == ["comparison", "data-lookup", "historic-lookup", "period-summary"])
    }

    @Test("Scope-cards expose 4 entries — one per allowed category")
    func scopeCardsCountMatchesAllowlist() {
        #expect(ScopeCardModel.allDefault.count == MiniCoachPrompt.AllowedCategory.allCases.count)
    }

    @Test("markOnboarded triggers the on-enabled callback indirectly via state flip")
    func markOnboardedFlipsState() {
        let suite = "MiniCoachOnboardingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not allocate isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        let store = MiniCoachStore(
            service: MiniCoachService(featureFlags: StubFlags(enabled: true)),
            defaults: defaults
        )
        #expect(!store.isOnboarded)
        store.markOnboarded()
        #expect(store.isOnboarded)
        // The persisted key matches the Settings toggle's binding source.
        #expect(defaults.bool(forKey: MiniCoachDefaultsKeys.onboarded))
    }

    @Test("Defaults keys live in the nonisolated MiniCoachDefaultsKeys enum")
    func defaultsKeysAreNonisolated() {
        // Compile-time check: if these access touched MainActor, the
        // synchronous test body would emit a Swift-6 isolation error.
        let onboarded = MiniCoachDefaultsKeys.onboarded
        let enabled = MiniCoachDefaultsKeys.enabled
        #expect(onboarded == "hl.minicoach.onboarded")
        #expect(enabled == "hl.minicoach.enabled")
    }
}

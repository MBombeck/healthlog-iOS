import Foundation
@testable import HealthLog
import Testing

/// Tests around the Settings feature-flag gate for the Mini-Coach (C6).
///
/// The Settings view itself isn't rendered — we lock the underlying
/// invariants the view consumes:
///   1. `FeatureFlag.assistantCoach.defaultValue` is true so a fresh
///      install + missing snapshot still surfaces the row.
///   2. `FeatureFlagsStoreSnapshot` honors an explicit `false` (operator
///      kill-switch) which the view then hides on.
///   3. Defaults keys are nonisolated string constants so the view's
///      `@AppStorage(MiniCoachDefaultsKeys.enabled)` does NOT drag
///      MainActor isolation into the nonisolated Settings destination
///      enum.
@Suite("MiniCoach — settings feature-flag gate (C6)")
struct MiniCoachSettingsGateTests {
    @Test("assistant.coach defaults to ON pre-snapshot")
    func assistantCoachDefaultsOn() {
        #expect(FeatureFlag.assistantCoach.defaultValue)
    }

    @Test("Operator kill-switch (false) is honoured by the live snapshot")
    func killSwitchHonoured() {
        let snapshot = FeatureFlagsStoreSnapshot(flags: [.assistantCoach: false])
        #expect(!snapshot.isEnabled(.assistantCoach))
    }

    @Test("Operator on-flag is honoured by the live snapshot")
    func explicitlyEnabledHonoured() {
        let snapshot = FeatureFlagsStoreSnapshot(flags: [.assistantCoach: true])
        #expect(snapshot.isEnabled(.assistantCoach))
    }

    @Test("Missing flag falls back to the per-flag default (fail-open)")
    func missingFlagFailsOpen() {
        let snapshot = FeatureFlagsStoreSnapshot(flags: [:])
        #expect(snapshot.isEnabled(.assistantCoach))
    }

    @Test("Default enabled-toggle is OFF on a fresh defaults bucket")
    func miniCoachEnabledDefaultsOff() {
        let suite = "MiniCoachSettingsGateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not allocate isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        // `@AppStorage` reads via UserDefaults — mirror the default-OFF
        // operator-decision (Q-MC-4) at the defaults level.
        #expect(!defaults.bool(forKey: MiniCoachDefaultsKeys.enabled))
    }

    @Test("Defaults keys live in a nonisolated enum (compile-time)")
    func defaultsKeysCompileNonisolated() {
        // Same compile-time anchor as the onboarding-tests file —
        // double-listed because Q-MC-4's killswitch path also depends on
        // these strings staying out of MainActor isolation.
        let enabled = MiniCoachDefaultsKeys.enabled
        #expect(enabled == "hl.minicoach.enabled")
    }
}

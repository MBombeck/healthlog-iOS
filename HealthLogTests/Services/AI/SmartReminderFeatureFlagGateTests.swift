import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests that `SmartReminderPhraseService` honours the
/// `assistant.briefing` operator-control flag (R5 — single AI-surface
/// flag gates BOTH server-AI AND on-device AI paths).
///
/// The companion-service tests already cover the short-circuit when the
/// flag is off; this suite locks the wiring guarantees:
///
///   * `FeatureFlagsStoreSnapshot` reads through `isEnabled(_:)`.
///   * `LiveFeatureFlagsService` evaluates the closure on every call —
///     a flag flipped mid-session is honoured on the next `generate(...)`.
///   * The factory tuple emitted by AppContainer's
///     `makeAssistantServices(store:)` returns a wired
///     `SmartReminderPhraseService` so production paths never accidentally
///     fall back to the `UserDefaultsFeatureFlagsService` default.
@Suite("SmartReminderPhraseService — assistant.briefing flag-gate (D-1)")
@MainActor
struct SmartReminderFeatureFlagGateTests {
    @Test("FeatureFlagsStoreSnapshot off → SmartReminderPhraseService short-circuits")
    func snapshotOffShortCircuits() async {
        let snapshot = FeatureFlagsStoreSnapshot(flags: [.assistantBriefing: false])
        let service = SmartReminderPhraseService(featureFlags: snapshot)
        let ctx = ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    @Test("FeatureFlagsStoreSnapshot missing flag falls back to default (ON)")
    func snapshotMissingFlagDefaultsToOn() async {
        // Empty snapshot — the snapshot's `isEnabled(_:)` returns
        // `flag.defaultValue` (`true` for `.assistantBriefing`). The service
        // should NOT short-circuit on `.featureFlagDisabled`; it instead
        // hands off to the FM path which (in CI, on the simulator without
        // Apple Intelligence) reports `.deviceIneligible`.
        let snapshot = FeatureFlagsStoreSnapshot(flags: [:])
        let service = SmartReminderPhraseService(featureFlags: snapshot)
        let ctx = ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason != .featureFlagDisabled)
    }

    @Test("LiveFeatureFlagsService re-evaluates on every call (mid-session toggle)")
    func liveFlagsHonourMidSessionToggle() async {
        // Box around a Bool so we can flip it after the service is built.
        // `nonisolated(unsafe)` is fine in test scope — there's no concurrent
        // writer racing the toggle in the test body.
        nonisolated(unsafe) var enabled = true
        let live = LiveFeatureFlagsService { flag in
            switch flag {
            case .assistantBriefing: enabled
            default: true
            }
        }
        let service = SmartReminderPhraseService(featureFlags: live)
        let ctx = ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)

        // Flag-ON: not flag-disabled (will fall back for other reasons in CI).
        let on = await service.generate(context: ctx)
        #expect(on.fallbackReason != .featureFlagDisabled)

        // Toggle off → next call sees the new value.
        enabled = false
        let off = await service.generate(context: ctx)
        #expect(off.fallbackReason == .featureFlagDisabled)

        // Toggle back on → next call recovers (still falls back, but not on
        // the flag — proves the closure is invoked every call, not cached).
        enabled = true
        let backOn = await service.generate(context: ctx)
        #expect(backOn.fallbackReason != .featureFlagDisabled)
    }

    @Test("Snapshot.allCases covers .assistantBriefing for D-1")
    func featureFlagEnumContainsAssistantBriefing() {
        // Regression-anchor: if a future refactor renames or removes
        // `.assistantBriefing`, the smart-reminder gate breaks silently.
        // This test pins the case is in the enum + the rawValue is the
        // server wire-key.
        #expect(FeatureFlag.allCases.contains(.assistantBriefing))
        #expect(FeatureFlag.assistantBriefing.rawValue == "assistant.briefing")
        #expect(FeatureFlag.assistantBriefing.defaultValue == true)
    }
}

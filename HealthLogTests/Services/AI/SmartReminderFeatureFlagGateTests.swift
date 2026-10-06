import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests that `SmartReminderPhraseService` honours the server-resolved
/// `briefing` AI capability (#114 / #115 · 0.2: `onDeviceAllowed`), which
/// replaced the never-delivered `assistant.briefing` flag.
///
/// The companion-service tests already cover the short-circuit when the
/// capability is closed; this suite locks the wiring guarantees:
///
///   * A fixed capability map reads through `allowsOnDevice(_:)`.
///   * The live ``AICapabilityGate`` reader is evaluated on every call — a
///     capability the next `/api/auth/me` load closes is honoured on the next
///     `generate(...)`.
///   * `AppContainer.makeAssistantServices(aiCapabilities:)` returns a service
///     wired to the reader it was handed.
@Suite("SmartReminderPhraseService — briefing capability gate (D-1, #115 0.2)")
@MainActor
struct SmartReminderFeatureFlagGateTests {
    private let ctx = ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)

    @Test("briefing onDeviceAllowed=false → SmartReminderPhraseService short-circuits")
    func snapshotOffShortCircuits() async {
        let service = SmartReminderPhraseService(aiCapabilities: AICaps.reader([.briefing: AICaps.operatorDisabled]))
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason == .capabilityNotAllowed)
    }

    @Test("A missing server provider keeps the on-device phrase (onDeviceAllowed=true)")
    func noProviderStillRunsOnDevice() async {
        let service = SmartReminderPhraseService(aiCapabilities: AICaps.reader([.briefing: AICaps.noProvider]))
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason != .capabilityNotAllowed)
    }

    @Test("No ai block (server < v1.39) → not short-circuited")
    func snapshotMissingFlagDefaultsToOn() async {
        // CI simulators have no Apple Intelligence, so the FM path reports
        // `.deviceIneligible` — the point is that it is NOT the capability.
        let service = SmartReminderPhraseService(aiCapabilities: LegacyAICapabilities())
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason != .capabilityNotAllowed)
    }

    @Test("The live gate reader re-evaluates on every call (mid-session change)")
    func liveFlagsHonourMidSessionToggle() async {
        let gate = AICapabilityGate()
        let service = SmartReminderPhraseService(aiCapabilities: gate.reader)

        let on = await service.generate(context: ctx)
        #expect(on.fallbackReason != .capabilityNotAllowed)

        gate.apply(AICaps.block([.briefing: AICaps.userDisabled]))
        let off = await service.generate(context: ctx)
        #expect(off.fallbackReason == .capabilityNotAllowed)

        gate.apply(AICaps.block())
        let backOn = await service.generate(context: ctx)
        #expect(backOn.fallbackReason != .capabilityNotAllowed)
    }

    @Test("makeAssistantServices wires every on-device assistant to the handed reader")
    func factoryWiresReader() async {
        let gate = AICapabilityGate(account: AICaps.block([
            .briefing: AICaps.operatorDisabled,
            .statusText: AICaps.operatorDisabled
        ]))
        let bundle = AppContainer.makeAssistantServices(aiCapabilities: gate.reader)
        let reminder = await bundle.smartReminder.generate(context: ctx)
        #expect(reminder.fallbackReason == .capabilityNotAllowed)
        let briefing = await bundle.briefing.generate(measurements: [], healthScore: nil, locale: Locale(identifier: "de_DE"))
        #expect(briefing.fallbackReason == .capabilityNotAllowed)
        let trend = await bundle.trend.observe(metric: .pulse, series: [], locale: Locale(identifier: "de_DE"))
        #expect(trend.fallbackReason == .capabilityNotAllowed)
    }
}

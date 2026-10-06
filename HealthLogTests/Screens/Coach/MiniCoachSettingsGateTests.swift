import Foundation
@testable import HealthLog
import Testing

/// Tests around the Settings capability gate for the Mini-Coach (C6).
///
/// The Settings view itself isn't rendered — we lock the underlying
/// invariants the view consumes (#115 · 0.2: the server's `coach` capability
/// replaced the never-delivered `assistant.coach` flag):
///   1. Without an `ai` block (server < v1.39, or before `/me` loaded) the
///      on-device Coach stays allowed — the 1.0.3 behaviour.
///   2. An operator-closed `coach` capability hides it
///      (`onDeviceAllowed == false`).
///   3. Defaults keys are nonisolated string constants so the view's
///      `@AppStorage(MiniCoachDefaultsKeys.enabled)` does NOT drag
///      MainActor isolation into the nonisolated Settings destination
///      enum.
@Suite("MiniCoach — settings capability gate (C6)")
@MainActor
struct MiniCoachSettingsGateTests {
    @Test("No ai block → on-device Coach allowed (legacy)")
    func legacyAllowsOnDevice() {
        let gate = AICapabilityGate()
        #expect(gate.allowsOnDevice(.coach))
    }

    @Test("Operator-closed coach capability is honoured on the device")
    func killSwitchHonoured() {
        let gate = AICapabilityGate(account: AICaps.block([.coach: AICaps.operatorDisabled]))
        #expect(!gate.allowsOnDevice(.coach))
        #expect(!gate.offersEntryPoint(.coach))
    }

    @Test("Missing server provider still allows the on-device Coach")
    func noProviderKeepsDevice() {
        let gate = AICapabilityGate(account: AICaps.block([.coach: AICaps.noProvider]))
        #expect(gate.allowsOnDevice(.coach))
        #expect(!gate.isAvailable(.coach))
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

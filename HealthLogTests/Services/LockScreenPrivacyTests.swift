import Foundation
@testable import HealthLog
import Testing

/// W-B188 (AUDIT-SEC-b187 High) — the device-local "hide medication name on
/// lock screen" opt-out. Pins the default-OFF contract + round-trip
/// persistence on an isolated `UserDefaults` suite (no shared-state leak into
/// the standard domain).
@Suite("LockScreenPrivacy — hide-medication-name opt-out")
struct LockScreenPrivacyTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "test.lockScreenPrivacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Defaults to OFF (current behaviour — real name shown)")
    func defaultsOff() throws {
        let defaults = try makeDefaults()
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == false)
    }

    @Test("Persists the opt-in choice")
    func persistsOn() throws {
        let defaults = try makeDefaults()
        LockScreenPrivacy.setHideMedicationName(true, defaults: defaults)
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == true)
    }

    @Test("Can be turned back off")
    func togglesBackOff() throws {
        let defaults = try makeDefaults()
        LockScreenPrivacy.setHideMedicationName(true, defaults: defaults)
        LockScreenPrivacy.setHideMedicationName(false, defaults: defaults)
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == false)
    }
}

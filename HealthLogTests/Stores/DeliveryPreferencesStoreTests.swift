import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.9.0 RA3** — pins the unified `DeliveryPreferencesStore`: effective
/// resolution (`localOverride ?? serverDefault ?? hardcodedDefault`), scope
/// writes, the `Sendable` predicate snapshot, the legacy Live-Activity
/// migration round-trip, and the stub-provider fallback (== today's
/// device-local behaviour).
@MainActor
@Suite("DeliveryPreferencesStore — unified per-med delivery prefs")
struct DeliveryPreferencesStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.deliveryPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Hardcoded defaults

    @Test("Both channels default OFF for an unset medication (stub provider)")
    func defaultsOff() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        let la = store.effective(medicationId: "m1", channel: .liveActivity)
        let ak = store.effective(medicationId: "m1", channel: .criticalAlarm)
        #expect(la.enabled == false)
        #expect(ak.enabled == false)
        // Hardcoded fallback surfaces as the user-level (roaming) scope.
        #expect(la.scope == .allDevices)
        #expect(ak.scope == .allDevices)
        #expect(DeliveryChannel.liveActivity.hardcodedDefault == false)
        #expect(DeliveryChannel.criticalAlarm.hardcodedDefault == false)
    }

    // MARK: - Local override

    @Test("Local override wins + reports thisDevice scope")
    func localOverrideWins() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        store.setLocalOverride(true, medicationId: "m1", channel: .criticalAlarm)
        let pref = store.effective(medicationId: "m1", channel: .criticalAlarm)
        #expect(pref.enabled == true)
        #expect(pref.scope == .thisDevice)
        // Channels are independent.
        #expect(store.isEnabled(medicationId: "m1", channel: .liveActivity) == false)
        // A different med is unaffected.
        #expect(store.isEnabled(medicationId: "m2", channel: .criticalAlarm) == false)
    }

    @Test("Clearing the local override falls back to the default")
    func clearOverride() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        store.setLocalOverride(true, medicationId: "m1", channel: .liveActivity)
        #expect(store.isEnabled(medicationId: "m1", channel: .liveActivity) == true)
        store.clearLocalOverride(medicationId: "m1", channel: .liveActivity)
        #expect(store.isEnabled(medicationId: "m1", channel: .liveActivity) == false)
    }

    // MARK: - Server-default layer

    @Test("Server default applies when no local override (allDevices scope)")
    func serverDefaultApplies() async {
        let provider = StubDeliveryDefaults(values: [
            "m1": MedicationDeliveryDefaultsDTO(
                medicationId: "m1",
                liveActivityEnabled: true,
                criticalAlarmEnabled: nil
            )
        ])
        let store = DeliveryPreferencesStore(defaults: makeDefaults(), provider: provider)
        await store.refreshServerDefaults(for: "m1")
        let la = store.effective(medicationId: "m1", channel: .liveActivity)
        #expect(la.enabled == true)
        #expect(la.scope == .allDevices)
        // Critical has no server value → hardcoded OFF.
        #expect(store.isEnabled(medicationId: "m1", channel: .criticalAlarm) == false)
    }

    @Test("Local override beats server default")
    func localBeatsServer() async {
        let provider = StubDeliveryDefaults(values: [
            "m1": MedicationDeliveryDefaultsDTO(
                medicationId: "m1",
                liveActivityEnabled: true,
                criticalAlarmEnabled: nil
            )
        ])
        let store = DeliveryPreferencesStore(defaults: makeDefaults(), provider: provider)
        await store.refreshServerDefaults(for: "m1")
        store.setLocalOverride(false, medicationId: "m1", channel: .liveActivity)
        let la = store.effective(medicationId: "m1", channel: .liveActivity)
        #expect(la.enabled == false)
        #expect(la.scope == .thisDevice)
    }

    // MARK: - Scope writes

    @Test("set(thisDevice) writes a local override and returns true")
    func setThisDevice() async {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        let ok = await store.set(
            enabled: true,
            scope: .thisDevice,
            medicationId: "m1",
            channel: .criticalAlarm
        )
        #expect(ok == true)
        #expect(store.effective(medicationId: "m1", channel: .criticalAlarm).scope == .thisDevice)
    }

    @Test("set(allDevices) with stub degrades to local + returns false (Server-Sync folgt)")
    func setAllDevicesStubDegrades() async {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        let ok = await store.set(
            enabled: true,
            scope: .allDevices,
            medicationId: "m1",
            channel: .criticalAlarm
        )
        // Stub provider throws .unsupported → degrades to local-only.
        #expect(ok == false)
        // The user's choice is still effective on this device, AND the
        // picker remembers the intended "Alle Geräte" scope (HIGH-6) even
        // though the value degraded to a local override.
        let pref = store.effective(medicationId: "m1", channel: .criticalAlarm)
        #expect(pref.enabled == true)
        #expect(pref.scope == .allDevices)
    }

    @Test("HIGH-6: an 'Alle Geräte' choice persists + reads back on reopen (stub)")
    func allDevicesScopePersistsAcrossReopen() async {
        let defaults = makeDefaults()
        let store = DeliveryPreferencesStore(defaults: defaults)
        _ = await store.set(
            enabled: true,
            scope: .allDevices,
            medicationId: "m1",
            channel: .criticalAlarm
        )
        // Simulate a sheet reopen — a fresh store over the same defaults.
        let reopened = DeliveryPreferencesStore(defaults: defaults)
        let pref = reopened.effective(medicationId: "m1", channel: .criticalAlarm)
        #expect(pref.enabled == true)
        // The picker must NOT have silently reverted to "Dieses Gerät".
        #expect(pref.scope == .allDevices)
    }

    @Test("Switching scope back to thisDevice is remembered on reopen")
    func thisDeviceScopePersistsAcrossReopen() async {
        let defaults = makeDefaults()
        let store = DeliveryPreferencesStore(defaults: defaults)
        _ = await store.set(enabled: true, scope: .allDevices, medicationId: "m1", channel: .liveActivity)
        _ = await store.set(enabled: true, scope: .thisDevice, medicationId: "m1", channel: .liveActivity)
        let reopened = DeliveryPreferencesStore(defaults: defaults)
        #expect(reopened.effective(medicationId: "m1", channel: .liveActivity).scope == .thisDevice)
    }

    @Test("set(allDevices) with a real provider clears the local override + roams")
    func setAllDevicesRealProvider() async {
        let provider = StubDeliveryDefaults(values: [:], acceptsWrites: true)
        let store = DeliveryPreferencesStore(defaults: makeDefaults(), provider: provider)
        store.setLocalOverride(false, medicationId: "m1", channel: .liveActivity)
        let ok = await store.set(
            enabled: true,
            scope: .allDevices,
            medicationId: "m1",
            channel: .liveActivity
        )
        #expect(ok == true)
        let pref = store.effective(medicationId: "m1", channel: .liveActivity)
        #expect(pref.enabled == true)
        #expect(pref.scope == .allDevices)
    }

    // MARK: - Predicate snapshot

    @Test("Predicate snapshot mirrors local + server + hardcoded fallback")
    func predicateSnapshot() async {
        let provider = StubDeliveryDefaults(values: [
            "server-on": MedicationDeliveryDefaultsDTO(
                medicationId: "server-on",
                liveActivityEnabled: nil,
                criticalAlarmEnabled: true
            )
        ])
        let store = DeliveryPreferencesStore(defaults: makeDefaults(), provider: provider)
        await store.refreshServerDefaults(for: "server-on")
        store.setLocalOverride(true, medicationId: "local-on", channel: .criticalAlarm)
        store.setLocalOverride(false, medicationId: "local-off", channel: .criticalAlarm)
        let predicate = store.enabledPredicate(for: .criticalAlarm)
        #expect(predicate("local-on") == true)
        #expect(predicate("local-off") == false)
        #expect(predicate("server-on") == true)
        #expect(predicate("never-set") == false)
    }

    // MARK: - Migration

    @Test("Legacy hl.liveActivity.enabled.* migrates into the unified scheme")
    func legacyMigration() {
        let defaults = makeDefaults()
        // Seed a legacy value before the store constructs.
        defaults.set(true, forKey: "\(DeliveryPreferencesStore.legacyLiveActivityPrefix)oldmed")
        let store = DeliveryPreferencesStore(defaults: defaults)
        let pref = store.effective(medicationId: "oldmed", channel: .liveActivity)
        #expect(pref.enabled == true)
        #expect(pref.scope == .thisDevice)
    }

    // MARK: - v1.7.0 SB-LA-1 / SB-AK-1 medication-contract booleans

    private func med(
        id: String,
        liveActivityEnabled: Bool? = nil,
        criticalAlarmEnabled: Bool? = nil
    ) -> Medication {
        Medication(
            id: id,
            name: "Med \(id)",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled
        )
    }

    @Test("ingestServerDefaults gates the predicate from the medication booleans")
    func ingestServerDefaultsGates() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        store.ingestServerDefaults(from: [
            med(id: "live-on", liveActivityEnabled: true, criticalAlarmEnabled: false),
            med(id: "alarm-on", liveActivityEnabled: false, criticalAlarmEnabled: true)
        ])
        let live = store.enabledPredicate(for: .liveActivity)
        let alarm = store.enabledPredicate(for: .criticalAlarm)
        #expect(live("live-on") == true)
        #expect(live("alarm-on") == false)
        #expect(alarm("alarm-on") == true)
        #expect(alarm("live-on") == false)
    }

    @Test("ingestServerDefaults skips meds with both booleans nil (current server)")
    func ingestServerDefaultsGracefulAbsence() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        // Current server: no fields → both nil. Nothing ingested → resolution
        // falls through to the hardcoded OFF default (unchanged behaviour).
        store.ingestServerDefaults(from: [med(id: "plain")])
        #expect(store.isEnabled(medicationId: "plain", channel: .liveActivity) == false)
        #expect(store.effective(medicationId: "plain", channel: .liveActivity).scope == .allDevices)
    }

    @Test("Local override still beats an ingested medication boolean")
    func localOverrideBeatsIngested() {
        let store = DeliveryPreferencesStore(defaults: makeDefaults())
        store.ingestServerDefaults(from: [med(id: "m1", liveActivityEnabled: false)])
        // The user explicitly turned it on for this device — overrides server.
        store.setLocalOverride(true, medicationId: "m1", channel: .liveActivity)
        #expect(store.enabledPredicate(for: .liveActivity)("m1") == true)
    }
}

/// Test double for the server-default seam — lets the resolution +
/// scope-write tests run without a live provider. `acceptsWrites` toggles
/// between the stub behaviour (throws `.unsupported`) and a real provider
/// that records writes into a shared box so a subsequent `defaults()` echo
/// reflects them (modelling the future server round-trip).
private struct StubDeliveryDefaults: DeliveryDefaultsProviding {
    let box: Box
    let acceptsWrites: Bool

    init(values: [String: MedicationDeliveryDefaultsDTO], acceptsWrites: Bool = false) {
        box = Box(values: values)
        self.acceptsWrites = acceptsWrites
    }

    func defaults(medicationId: String) async -> MedicationDeliveryDefaultsDTO? {
        await box.value(for: medicationId)
    }

    func setDefault(medicationId: String, channel: DeliveryChannel, enabled: Bool) async throws {
        guard acceptsWrites else { throw DeliveryDefaultsError.unsupported }
        await box.write(medicationId: medicationId, channel: channel, enabled: enabled)
    }

    actor Box {
        private var values: [String: MedicationDeliveryDefaultsDTO]
        init(values: [String: MedicationDeliveryDefaultsDTO]) {
            self.values = values
        }

        func value(for medicationId: String) -> MedicationDeliveryDefaultsDTO? {
            values[medicationId]
        }

        func write(medicationId: String, channel: DeliveryChannel, enabled: Bool) {
            let existing = values[medicationId]
            values[medicationId] = MedicationDeliveryDefaultsDTO(
                medicationId: medicationId,
                liveActivityEnabled: channel == .liveActivity ? enabled : existing?.liveActivityEnabled,
                criticalAlarmEnabled: channel == .criticalAlarm ? enabled : existing?.criticalAlarmEnabled
            )
        }
    }
}
